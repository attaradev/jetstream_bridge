# frozen_string_literal: true

require 'jetstream_bridge'
require 'jetstream_bridge/models/event_envelope'
require 'securerandom'

RSpec.describe JetstreamBridge::Models::EventEnvelope do
  before do
    JetstreamBridge.reset!
    JetstreamBridge.configure do |c|
      c.destination_app = 'dest'
      c.app_name        = 'test_app'
      c.env             = 'test'
    end
  end

  after { JetstreamBridge.reset! }
  describe '.new' do
    let(:valid_params) do
      {
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1, name: 'John' }
      }
    end

    it 'creates an envelope with required parameters' do
      envelope = described_class.new(**valid_params)

      expect(envelope.resource_type).to eq('User')
      expect(envelope.event_type).to eq('created')
      expect(envelope.payload).to eq({ id: 1, name: 'John' })
    end

    it 'generates a UUID for event_id if not provided' do
      envelope = described_class.new(**valid_params)

      expect(envelope.event_id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it 'accepts a custom event_id' do
      custom_id = SecureRandom.uuid
      envelope = described_class.new(**valid_params, event_id: custom_id)

      expect(envelope.event_id).to eq(custom_id)
    end

    it 'sets schema_version to 1' do
      envelope = described_class.new(**valid_params)

      expect(envelope.schema_version).to eq(1)
    end

    it 'sets occurred_at to current time if not provided' do
      freeze_time = Time.now.utc
      allow(Time).to receive(:now).and_return(freeze_time)

      envelope = described_class.new(**valid_params)

      expect(envelope.occurred_at).to eq(freeze_time)
    end

    it 'accepts a custom occurred_at timestamp' do
      custom_time = '2025-01-01T00:00:00Z'
      envelope = described_class.new(**valid_params, occurred_at: custom_time)

      expect(envelope.occurred_at).to eq(custom_time)
    end

    it 'sets producer if provided' do
      envelope = described_class.new(**valid_params, producer: 'my-app')

      expect(envelope.producer).to eq('my-app')
    end

    it 'sets resource_id if provided' do
      envelope = described_class.new(**valid_params, resource_id: 123)

      expect(envelope.resource_id).to eq(123)
    end

    it 'sets trace_id if provided' do
      trace_id = 'trace-123'
      envelope = described_class.new(**valid_params, trace_id: trace_id)

      expect(envelope.trace_id).to eq(trace_id)
    end

    it 'generates a random trace_id if not provided' do
      envelope = described_class.new(**valid_params)

      expect(envelope.trace_id).not_to be_nil
      expect(envelope.trace_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it 'accepts Time object for occurred_at' do
      time_obj = Time.utc(2025, 1, 15, 10, 30, 0)
      envelope = described_class.new(**valid_params, occurred_at: time_obj)

      expect(envelope.occurred_at).to eq(time_obj)
    end

    it 'extracts resource_id from payload with symbol key' do
      envelope = described_class.new(**valid_params, payload: { id: 999 })

      expect(envelope.resource_id).to eq('999')
    end

    it 'extracts resource_id from payload with string key' do
      envelope = described_class.new(**valid_params, payload: { 'id' => 888 })

      expect(envelope.resource_id).to eq('888')
    end

    it 'prefers explicit resource_id over payload id' do
      envelope = described_class.new(**valid_params, resource_id: 'explicit-123',
                                                     payload: { id: 456 })

      expect(envelope.resource_id).to eq('explicit-123')
    end

    it 'handles payload without id field' do
      envelope = described_class.new(**valid_params, payload: { name: 'test' })

      expect(envelope.resource_id).to eq('')
    end

    it 'handles non-hash payload for resource_id extraction' do
      envelope = described_class.new(**valid_params, payload: 'string payload',
                                                     resource_id: 'explicit-id')

      expect(envelope.resource_id).to eq('explicit-id')
    end

    it 'converts symbols to strings for resource_type and event_type' do
      envelope = described_class.new(
        resource_type: :user,
        event_type: :created,
        payload: {}
      )

      expect(envelope.resource_type).to eq('user')
      expect(envelope.event_type).to eq('created')
    end

    context 'validation' do
      it 'requires resource_type' do
        params = valid_params.dup
        params.delete(:resource_type)

        expect { described_class.new(**params) }.to raise_error(ArgumentError, /resource_type/)
      end

      it 'requires event_type' do
        params = valid_params.dup
        params.delete(:event_type)

        expect { described_class.new(**params) }.to raise_error(ArgumentError, /event_type/)
      end

      it 'requires payload' do
        params = valid_params.dup
        params.delete(:payload)

        expect { described_class.new(**params) }.to raise_error(ArgumentError, /payload/)
      end

      it 'rejects nil resource_type' do
        expect do
          described_class.new(**valid_params, resource_type: nil)
        end.to raise_error(ArgumentError, /resource_type.*blank/)
      end

      it 'rejects blank resource_type' do
        expect do
          described_class.new(**valid_params, resource_type: '')
        end.to raise_error(ArgumentError, /resource_type.*blank/)
      end

      it 'rejects nil event_type' do
        expect do
          described_class.new(**valid_params, event_type: nil)
        end.to raise_error(ArgumentError, /event_type.*blank/)
      end

      it 'rejects blank event_type' do
        expect do
          described_class.new(**valid_params, event_type: '')
        end.to raise_error(ArgumentError, /event_type.*blank/)
      end

      it 'rejects nil payload' do
        expect do
          described_class.new(**valid_params, payload: nil)
        end.to raise_error(ArgumentError, /payload.*nil/)
      end
    end
  end

  describe '#to_h' do
    it 'converts envelope to hash with all fields' do
      envelope = described_class.new(
        event_id: 'evt-123',
        resource_type: 'Order',
        event_type: 'shipped',
        payload: { order_id: 456 },
        producer: 'warehouse-app',
        resource_id: 456,
        occurred_at: '2025-11-22T12:00:00Z',
        trace_id: 'trace-789'
      )

      hash = envelope.to_h

      expect(hash).to eq({
                           schema_version: 1,
                           event_id: 'evt-123',
                           event_type: 'shipped',
                           producer: 'warehouse-app',
                           resource_type: 'Order',
                           resource_id: 456,
                           occurred_at: '2025-11-22T12:00:00Z',
                           trace_id: 'trace-789',
                           payload: { order_id: 456 }
                         })
    end

    it 'omits nil optional fields' do
      envelope = described_class.new(
        resource_type: 'Product',
        event_type: 'updated',
        payload: { sku: 'ABC-123' }
      )

      hash = envelope.to_h

      expect(hash[:producer]).to eq('test_app') # defaults to app_name
      expect(hash[:resource_id]).to be_nil
      expect(hash[:trace_id]).not_to be_nil # trace_id is always generated
      expect(hash).to have_key(:event_id)
      expect(hash).to have_key(:occurred_at)
    end

    it 'formats Time object as ISO8601 string' do
      time_obj = Time.utc(2025, 1, 15, 10, 30, 45)
      envelope = described_class.new(
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1 },
        occurred_at: time_obj
      )

      hash = envelope.to_h

      expect(hash[:occurred_at]).to eq(time_obj.iso8601)
    end

    it 'parses string occurred_at to Time and formats it' do
      time_string = '2025-01-01T00:00:00Z'
      envelope = described_class.new(
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1 },
        occurred_at: time_string
      )

      hash = envelope.to_h

      expect(hash[:occurred_at]).to be_a(String)
      expect(hash[:occurred_at]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    it 'omits resource_id key when empty string' do
      envelope = described_class.new(
        resource_type: 'Product',
        event_type: 'updated',
        payload: { name: 'test' },
        resource_id: ''
      )

      hash = envelope.to_h

      expect(hash).not_to have_key(:resource_id)
    end

    it 'includes resource_id when present and non-empty' do
      envelope = described_class.new(
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1 },
        resource_id: 123
      )

      hash = envelope.to_h

      expect(hash).to have_key(:resource_id)
      expect(hash[:resource_id]).to eq(123)
    end
  end

  describe '.from_h' do
    let(:hash_with_symbols) do
      {
        event_id: 'evt-123',
        event_type: 'created',
        producer: 'my-app',
        resource_type: 'User',
        resource_id: 456,
        occurred_at: '2025-01-15T10:00:00Z',
        trace_id: 'trace-456',
        payload: { name: 'Test' }
      }
    end

    let(:hash_with_strings) do
      {
        'event_id' => 'evt-456',
        'event_type' => 'updated',
        'producer' => 'other-app',
        'resource_type' => 'Order',
        'resource_id' => 789,
        'occurred_at' => '2025-01-16T12:00:00Z',
        'trace_id' => 'trace-789',
        'payload' => { 'total' => 100 }
      }
    end

    it 'creates envelope from hash with symbol keys' do
      envelope = described_class.from_h(hash_with_symbols)

      expect(envelope.event_id).to eq('evt-123')
      expect(envelope.event_type).to eq('created')
      expect(envelope.producer).to eq('my-app')
      expect(envelope.resource_type).to eq('User')
      expect(envelope.trace_id).to eq('trace-456')
    end

    it 'creates envelope from hash with string keys' do
      envelope = described_class.from_h(hash_with_strings)

      expect(envelope.event_id).to eq('evt-456')
      expect(envelope.event_type).to eq('updated')
      expect(envelope.producer).to eq('other-app')
      expect(envelope.resource_type).to eq('Order')
      expect(envelope.trace_id).to eq('trace-789')
    end

    it 'parses occurred_at string to Time' do
      envelope = described_class.from_h(hash_with_symbols)

      expect(envelope.occurred_at).to be_a(Time)
    end

    it 'handles missing optional fields' do
      minimal_hash = {
        resource_type: 'Product',
        event_type: 'deleted',
        payload: {}
      }

      envelope = described_class.from_h(minimal_hash)

      expect(envelope.event_id).not_to be_nil
      expect(envelope.occurred_at).to be_a(Time)
    end

    it 'defaults to empty payload when missing' do
      hash = {
        resource_type: 'Item',
        event_type: 'test'
      }

      envelope = described_class.from_h(hash)

      expect(envelope.payload).to eq({})
    end

    it 'round-trips through to_h' do
      original = described_class.new(
        resource_type: 'Widget',
        event_type: 'manufactured',
        payload: { serial: 'ABC-123' },
        producer: 'factory-app',
        resource_id: 555
      )

      hash = original.to_h
      reconstructed = described_class.from_h(hash)

      expect(reconstructed.event_id).to eq(original.event_id)
      expect(reconstructed.resource_type).to eq(original.resource_type)
      expect(reconstructed.event_type).to eq(original.event_type)
      expect(reconstructed.producer).to eq(original.producer)
    end

    it 'ignores schema_version in hash' do
      hash = {
        schema_version: 1,
        resource_type: 'Test',
        event_type: 'test',
        payload: {}
      }

      envelope = described_class.from_h(hash)

      expect(envelope.schema_version).to eq(1)
    end
  end

  describe 'equality and hashing' do
    let(:envelope1) do
      described_class.new(
        event_id: 'same-id',
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1 }
      )
    end

    let(:envelope2) do
      described_class.new(
        event_id: 'same-id',
        resource_type: 'Order',
        event_type: 'updated',
        payload: { id: 2 }
      )
    end

    let(:envelope3) do
      described_class.new(
        event_id: 'different-id',
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1 }
      )
    end

    it 'considers envelopes equal if they have the same event_id' do
      expect(envelope1).to eq(envelope2)
    end

    it 'considers envelopes not equal if they have different event_ids' do
      expect(envelope1).not_to eq(envelope3)
    end

    it 'implements eql? the same as ==' do
      expect(envelope1.eql?(envelope2)).to be true
      expect(envelope1.eql?(envelope3)).to be false
    end

    it 'generates same hash for envelopes with same event_id' do
      expect(envelope1.hash).to eq(envelope2.hash)
    end

    it 'allows use in hash keys' do
      hash_map = { envelope1 => 'value1' }
      hash_map[envelope2] = 'value2'

      expect(hash_map.size).to eq(1)
      expect(hash_map[envelope1]).to eq('value2')
    end

    it 'allows use in sets' do
      set = Set.new([envelope1, envelope2, envelope3])

      expect(set.size).to eq(2)
      expect(set).to include(envelope1)
      expect(set).to include(envelope3)
    end
  end

  describe 'immutability' do
    let(:envelope) do
      described_class.new(
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1 }
      )
    end

    it 'freezes the envelope instance' do
      expect(envelope).to be_frozen
    end

    it 'prevents modification of event_id' do
      expect { envelope.instance_variable_set(:@event_id, 'new-id') }.to raise_error(FrozenError)
    end

    it 'freezes the payload hash' do
      expect(envelope.payload).to be_frozen
    end

    it 'does not allow payload modification' do
      expect { envelope.payload[:new_key] = 'value' }.to raise_error(FrozenError)
    end

    it 'deeply freezes nested hash payloads' do
      envelope = described_class.new(
        resource_type: 'User',
        event_type: 'created',
        payload: { user: { name: 'John', address: { city: 'NYC' } } }
      )

      expect(envelope.payload).to be_frozen
      expect(envelope.payload[:user]).to be_frozen
      expect(envelope.payload[:user][:address]).to be_frozen
    end

    it 'deeply freezes array payloads' do
      envelope = described_class.new(
        resource_type: 'Order',
        event_type: 'created',
        payload: { items: [{ id: 1 }, { id: 2 }] }
      )

      expect(envelope.payload).to be_frozen
      expect(envelope.payload[:items]).to be_frozen
      expect(envelope.payload[:items][0]).to be_frozen
    end

    it 'freezes hash keys' do
      key = 'mutable_key'
      envelope = described_class.new(
        resource_type: 'Test',
        event_type: 'test',
        payload: { key => 'value' }
      )

      expect(envelope.payload.keys.first).to be_frozen
    end
  end

  describe 'error handling' do
    it 'falls back to current time for invalid occurred_at string' do
      freeze_time = Time.now.utc
      allow(Time).to receive(:now).and_return(freeze_time)

      envelope = described_class.new(
        resource_type: 'Test',
        event_type: 'test',
        payload: {},
        occurred_at: 'invalid-date-string'
      )

      expect(envelope.occurred_at).to eq(freeze_time)
    end

    it 'handles occurred_at as integer gracefully' do
      envelope = described_class.new(
        resource_type: 'Test',
        event_type: 'test',
        payload: {},
        occurred_at: 1_234_567_890
      )

      expect(envelope.occurred_at).to be_a(Time)
    end
  end

  describe 'schema version' do
    it 'has SCHEMA_VERSION constant set to 1' do
      expect(described_class::SCHEMA_VERSION).to eq(1)
    end

    it 'uses SCHEMA_VERSION in all envelopes' do
      envelope = described_class.new(
        resource_type: 'User',
        event_type: 'created',
        payload: { id: 1 }
      )

      expect(envelope.schema_version).to eq(described_class::SCHEMA_VERSION)
    end
  end
end
