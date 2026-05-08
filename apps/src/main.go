package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// config holds everything the app needs from the environment.
// All values come from environment variables injected via the
// Kubernetes Deployment — no hardcoded values in application code.
type config struct {
	teamName     string
	namespace    string
	port         string
	otelEndpoint string
}

// requestLog is the structured log shape written to stdout on
// every HTTP request. JSON format makes it parseable by the
// OTel filelog receiver without a custom operator.
type requestLog struct {
	Time      string `json:"time"`
	Method    string `json:"method"`
	Path      string `json:"path"`
	Status    int    `json:"status"`
	TraceID   string `json:"trace_id"`
	Team      string `json:"team"`
	Namespace string `json:"namespace"`
	Duration  string `json:"duration"`
}

// response is the JSON body returned to the caller.
type response struct {
	Message   string `json:"message"`
	Team      string `json:"team"`
	Namespace string `json:"namespace"`
	TraceID   string `json:"trace_id"`
}

func loadConfig() config {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	return config{
		teamName:     getEnvOrDefault("TEAM_NAME", "unknown"),
		namespace:    getEnvOrDefault("NAMESPACE", "unknown"),
		port:         port,
		otelEndpoint: getEnvOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
	}
}

func getEnvOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// initTracer sets up the OTel trace SDK with an OTLP gRPC exporter.
// Returns a shutdown function the caller must defer.
func initTracer(ctx context.Context, cfg config) (func(context.Context) error, error) {
	if cfg.otelEndpoint == "" {
		// No endpoint configured — run without tracing.
		// This keeps the app functional in environments
		// where OTel is not installed yet.
		return func(context.Context) error { return nil }, nil
	}

	conn, err := grpc.DialContext(ctx, cfg.otelEndpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to OTel collector: %w", err)
	}

	exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	res := resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(cfg.teamName+"-app"),
		semconv.DeploymentEnvironment("demo"),
		attribute.String("team", cfg.teamName),
		attribute.String("namespace", cfg.namespace),
	)

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(
		propagation.NewCompositeTextMapPropagator(
			propagation.TraceContext{},
			propagation.Baggage{},
		),
	)

	return tp.Shutdown, nil
}

// initMeter sets up the OTel metric SDK with an OTLP gRPC exporter.
// Returns a shutdown function the caller must defer.
func initMeter(ctx context.Context, cfg config) (func(context.Context) error, metric.Meter, error) {
	noop := func(context.Context) error { return nil }

	if cfg.otelEndpoint == "" {
		return noop, otel.GetMeterProvider().Meter(cfg.teamName), nil
	}

	conn, err := grpc.DialContext(ctx, cfg.otelEndpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return noop, nil, fmt.Errorf("failed to connect to OTel collector: %w", err)
	}

	exporter, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithGRPCConn(conn))
	if err != nil {
		return noop, nil, fmt.Errorf("failed to create metric exporter: %w", err)
	}

	res := resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(cfg.teamName+"-app"),
		attribute.String("team", cfg.teamName),
		attribute.String("namespace", cfg.namespace),
	)

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(
			sdkmetric.NewPeriodicReader(exporter,
				sdkmetric.WithInterval(15*time.Second),
			),
		),
		sdkmetric.WithResource(res),
	)

	otel.SetMeterProvider(mp)
	return mp.Shutdown, mp.Meter(cfg.teamName), nil
}

func main() {
	cfg := loadConfig()
	ctx := context.Background()

	// Initialise tracing
	shutdownTracer, err := initTracer(ctx, cfg)
	if err != nil {
		log.Printf("warning: tracing disabled: %v", err)
	}
	defer shutdownTracer(ctx)

	// Initialise metrics
	shutdownMeter, meter, err := initMeter(ctx, cfg)
	if err != nil {
		log.Printf("warning: metrics disabled: %v", err)
	}
	defer shutdownMeter(ctx)

	// HTTP request counter metric
	requestCounter, err := meter.Int64Counter(
		"http_requests_total",
		metric.WithDescription("Total number of HTTP requests"),
	)
	if err != nil {
		log.Fatalf("failed to create request counter: %v", err)
	}

	tracer := otel.Tracer(cfg.teamName)

	mux := http.NewServeMux()

	// Health check — used by Kubernetes liveness and readiness probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// Main application handler
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// Extract trace context from incoming headers.
		// If the Gateway or caller passed a traceparent header,
		// this picks it up and continues the same trace.
		// If not, a new trace is started.
		propagator := otel.GetTextMapPropagator()
		ctx := propagator.Extract(r.Context(), propagation.HeaderCarrier(r.Header))

		// Start a span for this request
		ctx, span := tracer.Start(ctx, r.Method+" "+r.URL.Path)
		defer span.End()

		span.SetAttributes(
			attribute.String("http.method", r.Method),
			attribute.String("http.path", r.URL.Path),
			attribute.String("team", cfg.teamName),
			attribute.String("namespace", cfg.namespace),
		)

		// Extract trace ID for logging and response
		traceID := span.SpanContext().TraceID().String()

		// Increment request counter with labels
		requestCounter.Add(ctx, 1,
			metric.WithAttributes(
				attribute.String("method", r.Method),
				attribute.String("path", r.URL.Path),
				attribute.String("team", cfg.teamName),
				attribute.String("namespace", cfg.namespace),
			),
		)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)

		resp := response{
			Message:   fmt.Sprintf("hello from %s", cfg.teamName),
			Team:      cfg.teamName,
			Namespace: cfg.namespace,
			TraceID:   traceID,
		}
		json.NewEncoder(w).Encode(resp)

		duration := time.Since(start)

		// Structured JSON log — parseable by OTel filelog receiver
		logEntry := requestLog{
			Time:      time.Now().UTC().Format(time.RFC3339),
			Method:    r.Method,
			Path:      r.URL.Path,
			Status:    http.StatusOK,
			TraceID:   traceID,
			Team:      cfg.teamName,
			Namespace: cfg.namespace,
			Duration:  duration.String(),
		}

		logBytes, _ := json.Marshal(logEntry)
		fmt.Println(string(logBytes))
	})

	addr := ":" + cfg.port
	log.Printf(`{"time":"%s","msg":"server starting","team":"%s","namespace":"%s","port":"%s"}`,
		time.Now().UTC().Format(time.RFC3339),
		cfg.teamName,
		cfg.namespace,
		cfg.port,
	)

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}
