# frozen_string_literal: true

require 'jetstream_bridge/core/config'

RSpec.describe JetstreamBridge::Config do
  let(:config) { described_class.new }

  describe '#initialize' do
    it 'sets default values' do
      expect(config.stream_name).to eq('jetstream-bridge-stream')
      expect(config.app_name).to eq('app')
      expect(config.max_deliver).to eq(5)
      expect(config.ack_wait).to eq('30s')
      expect(config.backoff).to eq(%w[1s 5s 15s 30s 60s])
      expect(config.use_outbox).to be false
      expect(config.use_inbox).to be false
      expect(config.use_dlq).to be true
    end

    it 'reads NATS_URLS from environment' do
      allow(ENV).to receive(:[]).with('NATS_URLS').and_return('nats://test:4222')
      allow(ENV).to receive(:[]).with('NATS_URL').and_return(nil)
      allow(ENV).to receive(:[]).with('JETSTREAM_STREAM_NAME').and_return(nil)
      allow(ENV).to receive(:[]).with('APP_NAME').and_return(nil)
      allow(ENV).to receive(:fetch).with('DESTINATION_APP', nil).and_return(nil)

      config = described_class.new

      expect(config.nats_urls).to eq('nats://test:4222')
    end

    it 'falls back to NATS_URL if NATS_URLS not set' do
      allow(ENV).to receive(:[]).with('NATS_URLS').and_return(nil)
      allow(ENV).to receive(:[]).with('NATS_URL').and_return('nats://fallback:4222')
      allow(ENV).to receive(:[]).with('JETSTREAM_STREAM_NAME').and_return(nil)
      allow(ENV).to receive(:[]).with('APP_NAME').and_return(nil)
      allow(ENV).to receive(:fetch).with('DESTINATION_APP', nil).and_return(nil)

      config = described_class.new

      expect(config.nats_urls).to eq('nats://fallback:4222')
    end
  end

  describe '#source_subject' do
    before do
      config.app_name = 'orders'
      config.destination_app = 'warehouse'
    end

    it 'creates subject in format app.sync.dest' do
      expect(config.source_subject).to eq('orders.sync.warehouse')
    end

    it 'validates app_name component' do
      config.app_name = 'app.'

      expect do
        config.source_subject
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /app_name.*wildcards/)
    end

    it 'validates destination_app component' do
      config.destination_app = 'dest>'

      expect do
        config.source_subject
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /destination_app.*wildcards/)
    end

    it 'raises error if destination_app is empty' do
      config.destination_app = ''

      expect do
        config.source_subject
      end.to raise_error(JetstreamBridge::MissingConfigurationError, /destination_app.*empty/)
    end
  end

  describe '#destination_subject' do
    before do
      config.app_name = 'warehouse'
      config.destination_app = 'orders'
    end

    it 'creates subject in format dest.sync.app' do
      expect(config.destination_subject).to eq('orders.sync.warehouse')
    end

    it 'swaps source and destination compared to source_subject' do
      expect(config.destination_subject).to eq('orders.sync.warehouse')
      expect(config.source_subject).to eq('warehouse.sync.orders')
    end
  end

  describe '#dlq_subject' do
    it 'creates DLQ subject with app name' do
      config.app_name = 'api'

      expect(config.dlq_subject).to eq('api.sync.dlq')
    end

    it 'validates app_name component' do
      config.app_name = 'app*'

      expect do
        config.dlq_subject
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /app_name.*wildcards/)
    end
  end

  describe '#durable_name' do
    it 'uses app_name as-is with -workers suffix' do
      config.app_name = 'notifications'

      expect(config.durable_name).to eq('notifications-workers')
    end
  end

  describe '#validate!' do
    before do
      config.destination_app = 'other_app'
      config.nats_urls = 'nats://localhost:4222'
      config.stream_name = 'jetstream-bridge-stream'
      config.app_name = 'my_app'
    end

    context 'with valid configuration' do
      it 'returns true' do
        expect(config.validate!).to be true
      end

      it 'does not raise error' do
        expect { config.validate! }.not_to raise_error
      end
    end

    context 'with missing destination_app' do
      it 'raises ConfigurationError' do
        config.destination_app = ''

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /destination_app is required/)
      end

      it 'treats nil as missing' do
        config.destination_app = nil

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /destination_app is required/)
      end

      it 'treats whitespace as missing' do
        config.destination_app = '   '

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /destination_app is required/)
      end
    end

    context 'with missing nats_urls' do
      it 'raises ConfigurationError' do
        config.nats_urls = ''

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /nats_urls is required/)
      end
    end

    context 'with missing stream_name' do
      it 'raises ConfigurationError' do
        config.stream_name = ''

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /stream_name is required/)
      end
    end

    context 'with missing app_name' do
      it 'raises ConfigurationError' do
        config.app_name = ''

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /app_name is required/)
      end
    end

    context 'with invalid max_deliver' do
      it 'raises error when max_deliver is 0' do
        config.max_deliver = 0

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /max_deliver must be >= 1/)
      end

      it 'raises error when max_deliver is negative' do
        config.max_deliver = -1

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /max_deliver must be >= 1/)
      end

      it 'accepts max_deliver of 1' do
        config.max_deliver = 1

        expect { config.validate! }.not_to raise_error
      end
    end

    context 'with invalid backoff' do
      it 'raises error when backoff is not an array' do
        config.backoff = '1s,5s,10s'

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /backoff must be an array/)
      end

      it 'raises error when backoff is empty array' do
        config.backoff = []

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /backoff must not be empty/)
      end

      it 'accepts non-empty array' do
        config.backoff = %w[1s 2s]

        expect { config.validate! }.not_to raise_error
      end
    end

    context 'with multiple errors' do
      it 'reports all errors in message' do
        config.destination_app = ''
        config.nats_urls = ''
        config.max_deliver = 0

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError) do |error|
          expect(error.message).to include('destination_app is required')
          expect(error.message).to include('nats_urls is required')
          expect(error.message).to include('max_deliver must be >= 1')
        end
      end
    end
  end

  describe '#validate_subject_component!' do
    it 'rejects wildcard *' do
      expect do
        config.send(:validate_subject_component!, 'app*name', 'test_field')
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /test_field.*wildcards/)
    end

    it 'rejects wildcard >' do
      expect do
        config.send(:validate_subject_component!, 'app>', 'test_field')
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /test_field.*wildcards/)
    end

    it 'rejects dot .' do
      expect do
        config.send(:validate_subject_component!, 'app.name', 'test_field')
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /test_field.*wildcards/)
    end

    it 'accepts valid component with underscores' do
      expect do
        config.send(:validate_subject_component!, 'my_app', 'test_field')
      end.not_to raise_error
    end

    it 'accepts valid component with dashes' do
      expect do
        config.send(:validate_subject_component!, 'my-app', 'test_field')
      end.not_to raise_error
    end

    it 'raises error for empty string' do
      expect do
        config.send(:validate_subject_component!, '', 'test_field')
      end.to raise_error(JetstreamBridge::MissingConfigurationError, /test_field.*empty/)
    end

    it 'raises error for whitespace-only string' do
      expect do
        config.send(:validate_subject_component!, '   ', 'test_field')
      end.to raise_error(JetstreamBridge::MissingConfigurationError, /test_field.*empty/)
    end

    it 'rejects components with spaces' do
      expect do
        config.send(:validate_subject_component!, 'prod test', 'test_field')
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /test_field.*invalid/)
    end

    it 'rejects components with control characters' do
      expect do
        config.send(:validate_subject_component!, "app\x01test", 'test_field')
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /test_field.*invalid/)
    end

    it 'rejects components with tab characters' do
      expect do
        config.send(:validate_subject_component!, "app\ttest", 'test_field')
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /test_field.*invalid/)
    end

    it 'rejects components exceeding 255 characters' do
      long_string = 'a' * 256
      expect do
        config.send(:validate_subject_component!, long_string, 'test_field')
      end.to raise_error(JetstreamBridge::InvalidSubjectError, /test_field.*maximum length/)
    end

    it 'accepts components at exactly 255 characters' do
      max_string = 'a' * 255
      expect do
        config.send(:validate_subject_component!, max_string, 'test_field')
      end.not_to raise_error
    end
  end

  describe 'model configuration' do
    it 'has default outbox model' do
      expect(config.outbox_model).to eq('JetstreamBridge::OutboxEvent')
    end

    it 'has default inbox model' do
      expect(config.inbox_model).to eq('JetstreamBridge::InboxEvent')
    end

    it 'allows custom outbox model' do
      config.outbox_model = 'CustomOutbox'

      expect(config.outbox_model).to eq('CustomOutbox')
    end

    it 'allows custom inbox model' do
      config.inbox_model = 'CustomInbox'

      expect(config.inbox_model).to eq('CustomInbox')
    end
  end

  describe 'consumer mode configuration' do
    describe '#initialize' do
      it 'defaults to pull consumer mode' do
        expect(config.consumer_mode).to eq(:pull)
      end

      it 'defaults delivery_subject to nil' do
        expect(config.delivery_subject).to be_nil
      end
    end

    describe '#pull_consumer?' do
      it 'returns true when consumer_mode is :pull' do
        config.consumer_mode = :pull
        expect(config.pull_consumer?).to be true
      end

      it 'returns false when consumer_mode is :push' do
        config.consumer_mode = :push
        expect(config.pull_consumer?).to be false
      end

      it 'handles string consumer_mode' do
        config.consumer_mode = 'pull'
        expect(config.pull_consumer?).to be true
      end
    end

    describe '#push_consumer?' do
      it 'returns false when consumer_mode is :pull' do
        config.consumer_mode = :pull
        expect(config.push_consumer?).to be false
      end

      it 'returns true when consumer_mode is :push' do
        config.consumer_mode = :push
        expect(config.push_consumer?).to be true
      end

      it 'handles string consumer_mode' do
        config.consumer_mode = 'push'
        expect(config.push_consumer?).to be true
      end
    end

    describe '#push_delivery_subject' do
      before do
        config.app_name = 'api'
        config.destination_app = 'worker'
      end

      it 'returns custom delivery_subject if set' do
        config.delivery_subject = 'custom.delivery.subject'
        expect(config.push_delivery_subject).to eq('custom.delivery.subject')
      end

      it 'returns default delivery subject when not set' do
        config.delivery_subject = nil
        expect(config.push_delivery_subject).to eq('worker.sync.api.worker')
      end

      it 'ignores empty string delivery_subject' do
        config.delivery_subject = ''
        expect(config.push_delivery_subject).to eq('worker.sync.api.worker')
      end

      it 'appends .worker to destination_subject' do
        expect(config.push_delivery_subject).to end_with('.worker')
      end
    end

    describe '#push_consumer_group_name' do
      before do
        config.app_name = 'api'
        config.destination_app = 'worker'
      end

      it 'returns custom group when set' do
        config.push_consumer_group = 'custom-group'
        expect(config.push_consumer_group_name).to eq('custom-group')
      end

      it 'defaults to durable_name when not set' do
        expect(config.push_consumer_group_name).to eq('api-workers')
      end

      it 'falls back to app_name when durable is empty' do
        allow(config).to receive(:durable_name).and_return('')
        expect(config.push_consumer_group_name).to eq('api')
      end

      it 'raises for invalid group names' do
        config.push_consumer_group = 'bad.*group'
        expect { config.push_consumer_group_name }.to raise_error(JetstreamBridge::InvalidSubjectError)
      end
    end

    describe '#validate! with consumer_mode' do
      before do
        config.destination_app = 'other_app'
        config.nats_urls = 'nats://localhost:4222'
        config.stream_name = 'jetstream-bridge-stream'
        config.app_name = 'my_app'
      end

      it 'accepts :pull consumer_mode' do
        config.consumer_mode = :pull
        expect { config.validate! }.not_to raise_error
      end

      it 'accepts :push consumer_mode' do
        config.consumer_mode = :push
        expect { config.validate! }.not_to raise_error
      end

      it 'accepts string "pull" consumer_mode' do
        config.consumer_mode = 'pull'
        expect { config.validate! }.not_to raise_error
      end

      it 'accepts string "push" consumer_mode' do
        config.consumer_mode = 'push'
        expect { config.validate! }.not_to raise_error
      end

      it 'validates push consumer group when using push mode' do
        config.consumer_mode = :push
        config.push_consumer_group = 'bad.*group'

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /bad.*group/)
      end

      it 'rejects invalid consumer_mode' do
        config.consumer_mode = :invalid

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /consumer_mode must be :pull or :push/)
      end

      it 'rejects nil consumer_mode' do
        config.consumer_mode = nil

        expect do
          config.validate!
        end.to raise_error(JetstreamBridge::ConfigurationError, /consumer_mode must be :pull or :push/)
      end
    end
  end
end
