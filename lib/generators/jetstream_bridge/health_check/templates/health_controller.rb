# frozen_string_literal: true

# Health check controller for JetStream Bridge monitoring
#
# This controller provides a health check endpoint for monitoring the JetStream
# connection status. Use it for Kubernetes liveness/readiness probes, Docker
# health checks, or load balancer health checks.
#
# Example usage:
#   GET /health/jetstream
#
# Returns:
#   200 OK - when healthy
#   503 Service Unavailable - when unhealthy
class JetstreamHealthController < ActionController::API
  # GET /health/jetstream
  #
  # Returns comprehensive health status including:
  # - NATS connection status
  # - JetStream stream information
  # - Configuration details
  # - Gem version
  def show
    health = JetstreamBridge.health_check

    if health[:healthy]
      render json: health, status: :ok
    else
      render json: health, status: :service_unavailable
    end
  rescue StandardError => e
    # Ensure we always return a valid JSON response
    render json: {
      healthy: false,
      error: "#{e.class}: #{e.message}"
    }, status: :service_unavailable
  end
end
