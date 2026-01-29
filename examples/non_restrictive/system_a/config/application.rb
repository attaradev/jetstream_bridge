# frozen_string_literal: true

require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'

Bundler.require(*Rails.groups)

module SystemA
  class Application < Rails::Application
    config.load_defaults 7.1
    config.api_only = true

    # Only load what we need for API-only app
    config.middleware.use ActionDispatch::Flash

    # Configure ActiveRecord
    config.active_record.schema_format = :ruby
  end
end
