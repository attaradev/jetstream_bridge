# frozen_string_literal: true

require_relative 'core/model_codec_setup'

module JetstreamBridge
  class Railtie < ::Rails::Railtie
    initializer 'jetstream_bridge.defer_model_tweaks' do
      ActiveSupport.on_load(:active_record) do
        ActiveSupport::Reloader.to_prepare { JetstreamBridge::ModelCodecSetup.apply! }
      end
    end

    rake_tasks do
      load File.expand_path('tasks/install.rake', __dir__)
    end
  end
end
