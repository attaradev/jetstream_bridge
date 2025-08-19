# frozen_string_literal: true

# lib/jetstream_bridge/railtie.rb
module JetstreamBridge
  class Railtie < ::Rails::Railtie
    initializer 'jetstream_bridge.defer_model_tweaks' do
      ActiveSupport.on_load(:active_record) do
        ActiveSupport::Reloader.to_prepare do
          # Skip if not connected (e.g., non-DB rake tasks)
          begin
            next unless ActiveRecord::Base.connected?
          rescue StandardError
            next
          end

          [JetstreamBridge::OutboxEvent, JetstreamBridge::InboxEvent].each do |klass|
            next unless klass.table_exists?

            %w[payload headers].each do |attr|
              next unless klass.columns_hash.key?(attr)

              # Only add serialize if the column is not JSON/JSONB
              type = klass.type_for_attribute(attr)
              klass.serialize attr.to_sym, coder: JSON unless type&.json?
            end
          rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
            # Ignore in tasks/environments without DB
          end
        end
      end
    end

    rake_tasks do
      load File.expand_path('tasks/install.rake', __dir__)
    end
  end
end
