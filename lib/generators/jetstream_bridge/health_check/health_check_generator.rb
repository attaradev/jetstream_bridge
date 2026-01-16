# frozen_string_literal: true

require 'rails/generators'

module JetstreamBridge
  module Generators
    class HealthCheckGenerator < ::Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)
      desc 'Creates a health check endpoint for JetStream Bridge monitoring'

      def create_controller
        template 'health_controller.rb', 'app/controllers/jetstream_health_controller.rb'
      end

      def add_route
        route_content = "  # JetStream Bridge health check endpoint\n  " \
                        "get '/health/jetstream', to: 'jetstream_health#show'"

        if File.exist?('config/routes.rb')
          inject_into_file 'config/routes.rb', after: /Rails\.application\.routes\.draw do\n/ do
            "#{route_content}\n"
          end
          say 'Added health check route to config/routes.rb', :green
        else
          say 'Could not find config/routes.rb - please add route manually:', :yellow
          say route_content, :yellow
        end
      end

      def show_usage
        say "\n#{'=' * 70}", :green
        say 'Health Check Endpoint Created!', :green
        say '=' * 70, :green
        say "\nThe health check endpoint is now available at:"
        say '  GET /health/jetstream', :cyan
        say "\nExample response:"
        say <<~EXAMPLE, :white
          {
            "healthy": true,
            "nats_connected": true,
            "connected_at": "2025-11-22T20:00:00Z",
            "stream": {
              "exists": true,
              "name": "development-jetstream-bridge-stream",
              "subjects": ["dev.app1.sync.app2"],
              "messages": 42
            },
            "config": {
              "env": "development",
              "app_name": "my_app",
              "destination_app": "other_app"
            },
            "version": "2.10.0"
          }
        EXAMPLE
        say "\nUse this endpoint for:"
        say '  • Kubernetes liveness/readiness probes', :white
        say '  • Docker health checks', :white
        say '  • Monitoring and alerting', :white
        say '  • Load balancer health checks', :white
        say '=' * 70, :green
      end
    end
  end
end
