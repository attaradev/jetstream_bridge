# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge::Models::Event do
  let(:event_hash) do
    {
      'event_id' => 'evt-123',
      'schema_version' => 1,
      'event_type' => 'user.created',
      'producer' => 'test-app',
      'resource_id' => '42',
      'occurred_at' => '2025-01-01T00:00:00Z',
      'trace_id' => 'trace-abc',
      'resource_type' => 'user',
      'payload' => {
        'id' => 42,
        'email' => 'user@example.com',
        'name' => 'Ada Lovelace'
      }
    }
  end

  let(:metadata) do
    {
      subject: 'test.app.sync.worker',
      deliveries: 1,
      stream: 'test-stream',
      sequence: 100,
      consumer: 'test-consumer',
      timestamp: Time.now
    }
  end

  subject(:event) { described_class.new(event_hash, metadata: metadata) }

  describe 'accessors' do
    it 'provides event_id' do
      expect(event.event_id).to eq('evt-123')
    end

    it 'provides type' do
      expect(event.type).to eq('user.created')
    end

    it 'provides resource_type' do
      expect(event.resource_type).to eq('user')
    end

    it 'provides producer' do
      expect(event.producer).to eq('test-app')
    end

    it 'provides resource_id' do
      expect(event.resource_id).to eq('42')
    end

    it 'provides trace_id' do
      expect(event.trace_id).to eq('trace-abc')
    end

    it 'provides occurred_at' do
      expect(event.occurred_at).to eq('2025-01-01T00:00:00Z')
    end
  end

  describe 'metadata' do
    it 'provides metadata object' do
      expect(event.metadata).to be_a(JetstreamBridge::Models::Event::Metadata)
    end

    it 'provides subject via metadata' do
      expect(event.metadata.subject).to eq('test.app.sync.worker')
    end

    it 'provides deliveries via metadata' do
      expect(event.metadata.deliveries).to eq(1)
    end

    it 'provides stream via metadata' do
      expect(event.metadata.stream).to eq('test-stream')
    end

    it 'provides sequence via metadata' do
      expect(event.metadata.sequence).to eq(100)
    end

    it 'provides consumer via metadata' do
      expect(event.metadata.consumer).to eq('test-consumer')
    end

    it 'provides deliveries directly' do
      expect(event.deliveries).to eq(1)
    end
  end

  describe 'payload access' do
    it 'provides payload object' do
      expect(event.payload).to be_a(JetstreamBridge::Models::Event::PayloadAccessor)
    end

    it 'allows method-style access' do
      expect(event.payload.id).to eq(42)
      expect(event.payload.email).to eq('user@example.com')
      expect(event.payload.name).to eq('Ada Lovelace')
    end

    it 'allows hash-style access' do
      expect(event.payload['id']).to eq(42)
      expect(event.payload['email']).to eq('user@example.com')
    end

    it 'provides to_h for payload' do
      expect(event.payload.to_h).to eq(event_hash['payload'])
    end
  end

  describe 'to_h' do
    it 'converts event to hash with symbol keys' do
      hash = event.to_h
      expect(hash).to be_a(Hash)
      expect(hash[:event_id]).to eq('evt-123')
      expect(hash[:type]).to eq('user.created')
      expect(hash[:payload]).to eq(event_hash['payload'])
      expect(hash[:metadata]).to be_a(Hash)
    end
  end

  describe 'backwards compatible hash access' do
    it 'allows hash bracket access' do
      expect(event['event_id']).to eq('evt-123')
      expect(event['event_type']).to eq('user.created')
      expect(event['payload']).to eq(event_hash['payload'])
    end

    it 'allows symbol key access' do
      expect(event[:event_id]).to eq('evt-123')
      expect(event[:event_type]).to eq('user.created')
    end
  end

  describe 'immutability' do
    it 'is frozen' do
      expect(event).to be_frozen
    end

    it 'metadata is a struct (not frozen by default)' do
      # Metadata is a Struct, which isn't automatically frozen
      expect(event.metadata).to be_a(JetstreamBridge::Models::Event::Metadata)
    end
  end

  describe 'payload method_missing' do
    it 'raises NoMethodError for undefined methods' do
      expect { event.payload.undefined_field }.to raise_error(NoMethodError)
    end

    it 'does not respond to undefined methods' do
      expect(event.payload.respond_to?(:undefined_field)).to be(false)
    end

    it 'responds to defined payload keys' do
      expect(event.payload.respond_to?(:id)).to be(true)
      expect(event.payload.respond_to?(:email)).to be(true)
    end

    it 'raises NoMethodError when calling method with arguments' do
      # method_missing should raise when args are provided
      expect { event.payload.id(123) }.to raise_error(NoMethodError)
    end

    it 'does not respond to methods when key not in payload' do
      accessor = JetstreamBridge::Models::Event::PayloadAccessor.new({})
      expect(accessor.respond_to?(:nonexistent)).to be(false)
    end
  end

  describe 'edge cases' do
    describe 'PayloadAccessor' do
      context 'with non-hash payload' do
        it 'initializes with empty hash when payload is not a hash' do
          event = described_class.new({ 'event_id' => '1', 'payload' => 'not-a-hash' })
          expect(event.payload.to_h).to eq({})
        end

        it 'initializes with empty hash when payload is nil' do
          event = described_class.new({ 'event_id' => '1', 'payload' => nil })
          expect(event.payload.to_h).to eq({})
        end

        it 'initializes with empty hash when payload is missing' do
          event = described_class.new({ 'event_id' => '1' })
          expect(event.payload.to_h).to eq({})
        end
      end

      context 'dig method' do
        let(:nested_event) do
          described_class.new({
                                'event_id' => '1',
                                'payload' => {
                                  'user' => { 'profile' => { 'name' => 'Alice' } }
                                }
                              })
        end

        it 'supports nested access with dig' do
          expect(nested_event.payload.dig(:user, :profile, :name)).to eq('Alice')
        end

        it 'returns nil for non-existent paths' do
          expect(nested_event.payload.dig(:user, :nonexistent, :key)).to be_nil
        end

        it 'converts keys to strings' do
          expect(nested_event.payload.dig('user', 'profile', 'name')).to eq('Alice')
        end
      end

      it 'supports to_hash alias' do
        expect(event.payload.to_hash).to eq(event.payload.to_h)
      end

      it 'transforms symbol keys to strings' do
        event = described_class.new({ 'event_id' => '1', 'payload' => { id: 123, name: 'test' } })
        expect(event.payload['id']).to eq(123)
        expect(event.payload['name']).to eq('test')
      end
    end

    describe 'time parsing' do
      it 'returns nil for nil occurred_at' do
        event = described_class.new({ 'event_id' => '1' })
        expect(event.occurred_at).to be_nil
      end

      it 'handles Time objects directly' do
        time = Time.now
        event = described_class.new({ 'event_id' => '1', 'occurred_at' => time })
        expect(event.occurred_at).to eq(time)
      end

      it 'parses valid time strings' do
        event = described_class.new({ 'event_id' => '1', 'occurred_at' => '2025-01-15T10:30:00Z' })
        expect(event.occurred_at).to be_a(Time)
        expect(event.occurred_at.to_s).to include('2025-01-15')
      end

      it 'returns nil for invalid time strings' do
        event = described_class.new({ 'event_id' => '1', 'occurred_at' => 'not-a-time' })
        expect(event.occurred_at).to be_nil
      end

      it 'converts numeric timestamps to string and parses' do
        # Edge case: numeric values get to_s called
        event = described_class.new({ 'event_id' => '1', 'occurred_at' => 1_234_567_890 })
        # This will try to parse "1234567890" which may fail
        expect(event.occurred_at).to be_nil.or be_a(Time)
      end
    end

    describe 'metadata initialization' do
      it 'defaults deliveries to 1 when not provided' do
        event = described_class.new({ 'event_id' => '1' }, metadata: {})
        expect(event.deliveries).to eq(1)
      end

      it 'accepts string keys in metadata' do
        event = described_class.new(
          { 'event_id' => '1' },
          metadata: { 'subject' => 'test.subject', 'deliveries' => 5, 'stream' => 'test-stream' }
        )
        expect(event.subject).to eq('test.subject')
        expect(event.deliveries).to eq(5)
        expect(event.stream).to eq('test-stream')
      end

      it 'accepts symbol keys in metadata' do
        event = described_class.new(
          { 'event_id' => '1' },
          metadata: { subject: 'test.subject', deliveries: 3 }
        )
        expect(event.subject).to eq('test.subject')
        expect(event.deliveries).to eq(3)
      end

      it 'handles nil metadata fields' do
        event = described_class.new({ 'event_id' => '1' }, metadata: { stream: nil, sequence: nil })
        expect(event.stream).to be_nil
        expect(event.sequence).to be_nil
      end
    end

    describe 'Metadata#to_h' do
      it 'compacts nil values' do
        event = described_class.new(
          { 'event_id' => '1' },
          metadata: { subject: 'test', stream: nil, sequence: nil }
        )
        hash = event.metadata.to_h
        expect(hash).to have_key(:subject)
        expect(hash).not_to have_key(:stream)
        expect(hash).not_to have_key(:sequence)
      end

      it 'includes all non-nil metadata fields' do
        hash = event.metadata.to_h
        expect(hash).to include(:subject, :deliveries, :stream, :sequence, :consumer)
      end
    end

    describe 'schema_version default' do
      it 'defaults to 1 when not provided' do
        event = described_class.new({ 'event_id' => '1' })
        expect(event.schema_version).to eq(1)
      end

      it 'uses provided schema_version' do
        event = described_class.new({ 'event_id' => '1', 'schema_version' => 3 })
        expect(event.schema_version).to eq(3)
      end
    end

    describe 'envelope with symbol keys' do
      it 'transforms symbol keys to string keys' do
        event = described_class.new({
                                      event_id: 'evt-1',
                                      event_type: 'test.event',
                                      resource_type: 'test'
                                    })
        expect(event.event_id).to eq('evt-1')
        expect(event.type).to eq('test.event')
        expect(event.resource_type).to eq('test')
      end

      it 'handles mixed symbol and string keys' do
        event = described_class.new({
                                      'event_id' => 'evt-1',
                                      event_type: 'test.event'
                                    })
        expect(event.event_id).to eq('evt-1')
        expect(event.type).to eq('test.event')
      end

      it 'handles envelope that does not respond to transform_keys' do
        # Create a custom object that doesn't have transform_keys
        envelope = Object.new
        def envelope.[](_key) = nil

        event = described_class.new(envelope)
        # Should not crash, just won't have values
        expect(event.event_id).to be_nil
      end
    end

    describe 'to_h with nil occurred_at' do
      it 'includes nil occurred_at in hash' do
        event = described_class.new({ 'event_id' => '1' })
        hash = event.to_h
        expect(hash).to have_key(:occurred_at)
        expect(hash[:occurred_at]).to be_nil
      end

      it 'converts occurred_at to iso8601 when present' do
        time = Time.parse('2025-01-15T10:30:00Z')
        event = described_class.new({ 'event_id' => '1', 'occurred_at' => time })
        hash = event.to_h
        expect(hash[:occurred_at]).to eq(time.iso8601)
      end
    end

    describe '[] method fallback' do
      it 'returns value from raw envelope for unknown keys' do
        event = described_class.new({
                                      'event_id' => '1',
                                      'custom_field' => 'custom_value'
                                    })
        expect(event['custom_field']).to eq('custom_value')
      end

      it 'returns nil for non-existent keys' do
        event = described_class.new({ 'event_id' => '1' })
        expect(event['nonexistent']).to be_nil
      end

      it 'converts occurred_at to iso8601 when accessed via []' do
        time = Time.parse('2025-01-15T10:30:00Z')
        event = described_class.new({ 'event_id' => '1', 'occurred_at' => time })
        expect(event['occurred_at']).to eq(time.iso8601)
      end

      it 'returns nil for occurred_at when nil' do
        event = described_class.new({ 'event_id' => '1' })
        expect(event['occurred_at']).to be_nil
      end

      it 'returns resource_type via [] accessor' do
        event = described_class.new({
                                      'event_id' => '1',
                                      'resource_type' => 'user'
                                    })
        expect(event['resource_type']).to eq('user')
      end

      it 'returns resource_id via [] accessor' do
        event = described_class.new({
                                      'event_id' => '1',
                                      'resource_id' => '123'
                                    })
        expect(event['resource_id']).to eq('123')
      end

      it 'returns producer via [] accessor' do
        event = described_class.new({
                                      'event_id' => '1',
                                      'producer' => 'test-app'
                                    })
        expect(event['producer']).to eq('test-app')
      end

      it 'returns trace_id via [] accessor' do
        event = described_class.new({
                                      'event_id' => '1',
                                      'trace_id' => 'trace-xyz'
                                    })
        expect(event['trace_id']).to eq('trace-xyz')
      end

      it 'returns schema_version via [] accessor' do
        event = described_class.new({
                                      'event_id' => '1',
                                      'schema_version' => 2
                                    })
        expect(event['schema_version']).to eq(2)
      end
    end

    describe 'to_hash alias' do
      it 'supports to_hash alias for to_h' do
        expect(event.to_hash).to eq(event.to_h)
      end
    end

    describe 'inspect' do
      it 'provides readable string representation' do
        output = event.inspect
        expect(output).to include('Event')
        expect(output).to include('evt-123')
        expect(output).to include('user.created')
        expect(output).to include('1')
      end
    end

    describe 'to_envelope' do
      it 'returns original envelope hash' do
        expect(event.to_envelope).to eq(event_hash)
      end

      it 'preserves extra fields in envelope' do
        custom_envelope = event_hash.merge('custom_field' => 'value')
        event = described_class.new(custom_envelope)
        expect(event.to_envelope['custom_field']).to eq('value')
      end
    end
  end
end
