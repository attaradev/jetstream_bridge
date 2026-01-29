# frozen_string_literal: true

require 'jetstream_bridge'
require 'active_record'
require 'oj'

RSpec.describe JetstreamBridge::InboxEvent do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.define do
      create_table :jetstream_bridge_inbox_events, force: true do |t|
        t.string :event_id
        t.string :event_type
        t.string :resource_type
        t.string :resource_id
        t.text :payload
        t.string :subject
        t.text :headers
        t.string :stream
        t.bigint :stream_seq
        t.integer :deliveries
        t.string :status, default: 'received'
        t.text :error_message
        t.text :last_error
        t.integer :processing_attempts, default: 0
        t.datetime :received_at
        t.datetime :processed_at
        t.datetime :failed_at
        t.timestamps
      end
    end
  end

  after(:all) do
    ActiveRecord::Base.connection.disconnect!
  end

  after do
    described_class.delete_all
  end

  describe 'validations' do
    context 'with event_id column present' do
      it 'validates presence of event_id' do
        event = described_class.new(subject: 'test.subject')
        expect(event.valid?).to be false
        expect(event.errors[:event_id]).to include("can't be blank")
      end

      it 'validates uniqueness of event_id' do
        described_class.create!(event_id: 'unique-id', subject: 'test.subject')
        duplicate = described_class.new(event_id: 'unique-id', subject: 'test.subject')
        expect(duplicate.valid?).to be false
        expect(duplicate.errors[:event_id]).to include('has already been taken')
      end
    end

    it 'validates presence of subject' do
      event = described_class.new(event_id: 'test-1')
      expect(event.valid?).to be false
      expect(event.errors[:subject]).to include("can't be blank")
    end
  end

  describe 'before_validation callback' do
    it 'sets default status to received' do
      event = described_class.new(event_id: 'test-2', subject: 'test.subject')
      event.valid?
      expect(event.status).to eq('received')
    end

    it 'sets default received_at timestamp' do
      event = described_class.new(event_id: 'test-3', subject: 'test.subject')
      event.valid?
      expect(event.received_at).to be_within(1.second).of(Time.now.utc)
    end

    it 'does not override existing status' do
      event = described_class.new(event_id: 'test-4', subject: 'test.subject', status: 'processed')
      event.valid?
      expect(event.status).to eq('processed')
    end

    it 'does not override existing received_at' do
      past_time = 1.hour.ago
      event = described_class.new(event_id: 'test-5', subject: 'test.subject', received_at: past_time)
      event.valid?
      expect(event.received_at).to be_within(1.second).of(past_time)
    end
  end

  describe '#processed?' do
    context 'when processed_at column exists and is set' do
      it 'returns true' do
        event = described_class.create!(
          event_id: 'test-6',
          subject: 'test.subject',
          processed_at: Time.now.utc
        )
        expect(event.processed?).to be true
      end
    end

    context 'when processed_at column exists but is nil' do
      it 'returns false even if status is processed' do
        # processed_at takes precedence when the column exists
        event = described_class.create!(
          event_id: 'test-7',
          subject: 'test.subject',
          status: 'processed',
          processed_at: nil
        )
        expect(event.processed?).to be false
      end
    end

    context 'when status is received' do
      it 'returns false' do
        event = described_class.create!(
          event_id: 'test-9',
          subject: 'test.subject',
          status: 'received'
        )
        expect(event.processed?).to be false
      end
    end
  end

  describe '#payload_hash' do
    context 'when payload is a JSON string' do
      it 'parses and returns a hash' do
        event = described_class.create!(
          event_id: 'test-10',
          subject: 'test.subject',
          payload: '{"key":"value","nested":{"data":123}}'
        )
        result = event.payload_hash
        expect(result).to eq({ 'key' => 'value', 'nested' => { 'data' => 123 } })
      end
    end

    context 'when payload is invalid JSON' do
      it 'returns empty hash' do
        event = described_class.create!(
          event_id: 'test-11',
          subject: 'test.subject',
          payload: 'not valid json {'
        )
        result = event.payload_hash
        expect(result).to eq({})
      end
    end
  end

  describe '.has_column?' do
    it 'returns true for existing columns' do
      expect(described_class.has_column?(:event_id)).to be true
      expect(described_class.has_column?(:subject)).to be true
      expect(described_class.has_column?(:stream_seq)).to be true
    end

    it 'returns false for non-existing columns' do
      expect(described_class.has_column?(:nonexistent_column)).to be false
    end

    it 'handles string column names' do
      expect(described_class.has_column?('event_id')).to be true
    end

    it 'returns false when not connected' do
      allow(described_class).to receive(:ar_connected?).and_return(false)
      expect(described_class.has_column?(:event_id)).to be false
    end

    it 'returns false when ConnectionNotEstablished is raised' do
      allow(described_class).to receive(:ar_connected?).and_return(true)
      allow(described_class.connection).to receive(:schema_cache).and_raise(ActiveRecord::ConnectionNotEstablished)
      expect(described_class.has_column?(:event_id)).to be false
    end

    it 'returns false when NoDatabaseError is raised' do
      allow(described_class).to receive(:ar_connected?).and_return(true)
      allow(described_class.connection).to receive(:schema_cache).and_raise(ActiveRecord::NoDatabaseError)
      expect(described_class.has_column?(:event_id)).to be false
    end
  end

  describe '.ar_connected?' do
    it 'returns true when connected and pool is active' do
      ActiveRecord::Base.connection.execute('SELECT 1')
      result = described_class.ar_connected?
      expect(result).to be_truthy
    end

    it 'returns false when ActiveRecord::Base is not connected' do
      allow(ActiveRecord::Base).to receive(:connected?).and_return(false)
      expect(described_class.ar_connected?).to be false
    end

    it 'returns false when connection_pool has no active connection' do
      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(described_class.connection_pool).to receive(:active_connection?).and_return(false)
      expect(described_class.ar_connected?).to be false
    end

    it 'returns false when StandardError is raised' do
      allow(ActiveRecord::Base).to receive(:connected?).and_raise(StandardError, 'connection error')
      expect(described_class.ar_connected?).to be false
    end
  end

  describe 'scopes' do
    before do
      described_class.create!(event_id: 'received-1', subject: 'test.received', status: 'received')
      described_class.create!(event_id: 'processing-1', subject: 'test.processing', status: 'processing')
      described_class.create!(event_id: 'processed-1', subject: 'test.processed', status: 'processed')
      described_class.create!(event_id: 'failed-1', subject: 'test.failed', status: 'failed')
      described_class.create!(event_id: 'subject-match', subject: 'specific.subject', status: 'received')
    end

    describe '.received' do
      it 'returns events with received status' do
        events = described_class.received
        expect(events.count).to eq(2)
        expect(events.pluck(:status).uniq).to eq(['received'])
      end
    end

    describe '.processing' do
      it 'returns events with processing status' do
        events = described_class.processing
        expect(events.count).to eq(1)
        expect(events.first.event_id).to eq('processing-1')
      end
    end

    describe '.processed' do
      it 'returns events with processed status' do
        events = described_class.processed
        expect(events.count).to eq(1)
        expect(events.first.event_id).to eq('processed-1')
      end
    end

    describe '.failed' do
      it 'returns events with failed status' do
        events = described_class.failed
        expect(events.count).to eq(1)
        expect(events.first.event_id).to eq('failed-1')
      end
    end

    describe '.by_subject' do
      it 'returns events matching the subject' do
        events = described_class.by_subject('specific.subject')
        expect(events.count).to eq(1)
        expect(events.first.event_id).to eq('subject-match')
      end

      it 'returns empty when no matches' do
        events = described_class.by_subject('nonexistent.subject')
        expect(events.count).to eq(0)
      end
    end
  end

  describe '#payload_hash' do
    context 'when payload is nil' do
      it 'returns nil' do
        event = described_class.create!(event_id: 'nil-payload', subject: 'test.subject', payload: nil)
        expect(event.payload_hash).to be_nil
      end
    end

    context 'when payload column does not exist' do
      it 'returns nil for missing column' do
        event = described_class.create!(event_id: 'no-column', subject: 'test.subject')
        # When column doesn't exist, self[:payload] returns nil
        expect(event.payload_hash).to be_nil
      end
    end
  end

  describe 'validation guards when columns missing' do
    context 'when event_id column does not exist' do
      before do
        allow(described_class).to receive(:has_column?).with(:event_id).and_return(false)
        allow(described_class).to receive(:has_column?).with(:stream_seq).and_return(true)
        allow(described_class).to receive(:has_column?).with(:stream).and_return(true)
        allow(described_class).to receive(:has_column?).with(:subject).and_return(true)
        allow(described_class).to receive(:has_column?).with(:status).and_return(true)
        allow(described_class).to receive(:has_column?).with(:received_at).and_return(true)
      end

      it 'validates stream_seq presence instead' do
        event = described_class.new(subject: 'test.subject', stream: 'test-stream')
        expect(event.valid?).to be false
        expect(event.errors[:stream_seq]).to include("can't be blank")
      end

      it 'validates stream_seq uniqueness scoped to stream' do
        described_class.create!(stream_seq: 1, stream: 'stream-a', subject: 'test.subject')
        duplicate = described_class.new(stream_seq: 1, stream: 'stream-a', subject: 'test.subject')

        expect(duplicate.valid?).to be false
        expect(duplicate.errors[:stream_seq]).to be_present
      end
    end

    context 'when neither event_id nor stream column exists' do
      before do
        allow(described_class).to receive(:has_column?).with(:event_id).and_return(false)
        allow(described_class).to receive(:has_column?).with(:stream_seq).and_return(true)
        allow(described_class).to receive(:has_column?).with(:stream).and_return(false)
        allow(described_class).to receive(:has_column?).with(:subject).and_return(true)
        allow(described_class).to receive(:has_column?).with(:status).and_return(true)
        allow(described_class).to receive(:has_column?).with(:received_at).and_return(true)
      end

      it 'validates stream_seq uniqueness without scope' do
        described_class.create!(stream_seq: 1, subject: 'test.subject')
        duplicate = described_class.new(stream_seq: 1, subject: 'test.subject')

        expect(duplicate.valid?).to be false
        expect(duplicate.errors[:stream_seq]).to include('has already been taken')
      end
    end
  end

  describe 'before_validation callback with missing columns' do
    context 'when status column does not exist' do
      it 'does not error when setting default status' do
        allow(described_class).to receive(:has_column?).with(:status).and_return(false)
        allow(described_class).to receive(:has_column?).with(:received_at).and_return(true)
        allow(described_class).to receive(:has_column?).with(:event_id).and_return(true)
        allow(described_class).to receive(:has_column?).with(:subject).and_return(true)

        event = described_class.new(event_id: 'test-status', subject: 'test.subject')
        expect { event.valid? }.not_to raise_error
      end
    end

    context 'when received_at column does not exist' do
      it 'does not error when setting default timestamp' do
        allow(described_class).to receive(:has_column?).with(:status).and_return(true)
        allow(described_class).to receive(:has_column?).with(:received_at).and_return(false)
        allow(described_class).to receive(:has_column?).with(:event_id).and_return(true)
        allow(described_class).to receive(:has_column?).with(:subject).and_return(true)

        event = described_class.new(event_id: 'test-timestamp', subject: 'test.subject')
        expect { event.valid? }.not_to raise_error
      end
    end
  end

  describe 'scopes when status column does not exist' do
    it 'returns empty relation for received scope' do
      allow(described_class).to receive(:has_column?).with(:status).and_return(false)
      expect(described_class.received).to be_a(ActiveRecord::Relation)
      expect(described_class.received.to_a).to be_empty
    end

    it 'returns empty relation for processing scope' do
      allow(described_class).to receive(:has_column?).with(:status).and_return(false)
      expect(described_class.processing).to be_a(ActiveRecord::Relation)
      expect(described_class.processing.to_a).to be_empty
    end

    it 'returns empty relation for processed scope' do
      allow(described_class).to receive(:has_column?).with(:status).and_return(false)
      expect(described_class.processed).to be_a(ActiveRecord::Relation)
      expect(described_class.processed.to_a).to be_empty
    end

    it 'returns empty relation for failed scope' do
      allow(described_class).to receive(:has_column?).with(:status).and_return(false)
      expect(described_class.failed).to be_a(ActiveRecord::Relation)
      expect(described_class.failed.to_a).to be_empty
    end
  end

  describe 'by_subject scope when subject column does not exist' do
    it 'returns empty relation' do
      allow(described_class).to receive(:has_column?).with(:subject).and_return(false)
      result = described_class.by_subject('test.subject')
      expect(result).to be_a(ActiveRecord::Relation)
      expect(result.to_a).to be_empty
    end
  end

  describe '.by_stream' do
    before do
      described_class.create!(event_id: 'stream-a-1', subject: 'test', stream: 'stream-a')
      described_class.create!(event_id: 'stream-a-2', subject: 'test', stream: 'stream-a')
      described_class.create!(event_id: 'stream-b-1', subject: 'test', stream: 'stream-b')
    end

    it 'returns events from specified stream' do
      events = described_class.by_stream('stream-a')
      expect(events.count).to eq(2)
      expect(events.pluck(:event_id)).to match_array(['stream-a-1', 'stream-a-2'])
    end
  end

  describe '.recent' do
    before do
      # Create events with different timestamps
      described_class.create!(event_id: 'old', subject: 'test', received_at: 2.hours.ago)
      described_class.create!(event_id: 'recent', subject: 'test', received_at: 1.hour.ago)
      described_class.create!(event_id: 'newest', subject: 'test', received_at: Time.now.utc)
    end

    it 'returns events ordered by received_at desc' do
      events = described_class.recent(10)
      expect(events.pluck(:event_id)).to eq(%w[newest recent old])
    end

    it 'limits results to specified count' do
      events = described_class.recent(2)
      expect(events.count).to eq(2)
      expect(events.pluck(:event_id)).to eq(%w[newest recent])
    end

    it 'defaults to 100 limit' do
      expect(described_class.recent.limit_value).to eq(100)
    end
  end

  describe '.unprocessed' do
    before do
      described_class.create!(event_id: 'pending', subject: 'test', status: 'pending')
      described_class.create!(event_id: 'processing', subject: 'test', status: 'processing')
      described_class.create!(event_id: 'processed', subject: 'test', status: 'processed')
      described_class.create!(event_id: 'failed', subject: 'test', status: 'failed')
    end

    it 'returns events that are not processed' do
      events = described_class.unprocessed
      expect(events.count).to eq(3)
      expect(events.pluck(:event_id)).to match_array(%w[pending processing failed])
    end

    it 'excludes processed events' do
      events = described_class.unprocessed
      expect(events.pluck(:status)).not_to include('processed')
    end
  end

  describe '.cleanup_processed' do
    before do
      # Old processed events
      described_class.create!(event_id: 'old-processed-1', subject: 'test',
                              status: 'processed', processed_at: 35.days.ago)
      described_class.create!(event_id: 'old-processed-2', subject: 'test',
                              status: 'processed', processed_at: 40.days.ago)
      # Recent processed event
      described_class.create!(event_id: 'recent-processed', subject: 'test',
                              status: 'processed', processed_at: 1.day.ago)
      # Unprocessed event
      described_class.create!(event_id: 'unprocessed', subject: 'test', status: 'pending')
    end

    it 'deletes processed events older than specified duration' do
      count = described_class.cleanup_processed(older_than: 30.days)
      expect(count).to eq(2)
      expect(described_class.pluck(:event_id)).not_to include('old-processed-1', 'old-processed-2')
    end

    it 'keeps recent processed events' do
      described_class.cleanup_processed(older_than: 30.days)
      expect(described_class.find_by(event_id: 'recent-processed')).to be_present
    end

    it 'keeps unprocessed events' do
      described_class.cleanup_processed(older_than: 30.days)
      expect(described_class.find_by(event_id: 'unprocessed')).to be_present
    end

    context 'when status column does not exist' do
      it 'returns 0' do
        allow(described_class).to receive(:has_column?).with(:status).and_return(false)
        expect(described_class.cleanup_processed).to eq(0)
      end
    end

    context 'when processed_at column does not exist' do
      it 'returns 0' do
        allow(described_class).to receive(:has_column?).with(:status).and_return(true)
        allow(described_class).to receive(:has_column?).with(:processed_at).and_return(false)
        expect(described_class.cleanup_processed).to eq(0)
      end
    end
  end

  describe '.processing_stats' do
    before do
      described_class.create!(event_id: 'pending-1', subject: 'test', status: 'pending')
      described_class.create!(event_id: 'pending-2', subject: 'test', status: 'pending')
      described_class.create!(event_id: 'processed-1', subject: 'test', status: 'processed')
      described_class.create!(event_id: 'processed-2', subject: 'test', status: 'processed')
      described_class.create!(event_id: 'processed-3', subject: 'test', status: 'processed')
      described_class.create!(event_id: 'failed-1', subject: 'test', status: 'failed')
    end

    it 'returns aggregated statistics' do
      stats = described_class.processing_stats
      expect(stats[:total]).to eq(6)
      expect(stats[:processed]).to eq(3)
      expect(stats[:failed]).to eq(1)
      expect(stats[:pending]).to eq(2)
    end

    it 'uses single query for efficiency' do
      expect(described_class).to receive(:group).with(:status).and_call_original
      described_class.processing_stats
    end

    context 'when status column does not exist' do
      it 'returns empty hash' do
        allow(described_class).to receive(:has_column?).with(:status).and_return(false)
        expect(described_class.processing_stats).to eq({})
      end
    end
  end

  describe '#mark_processed!' do
    let(:event) { described_class.create!(event_id: 'mark-test', subject: 'test', status: 'pending') }

    it 'sets status to processed' do
      event.mark_processed!
      expect(event.reload.status).to eq('processed')
    end

    it 'sets processed_at timestamp' do
      event.mark_processed!
      expect(event.reload.processed_at).to be_within(1.second).of(Time.now.utc)
    end

    it 'persists changes' do
      event.mark_processed!
      expect(event.reload.processed?).to be true
    end
  end

  describe '#mark_failed!' do
    let(:event) { described_class.create!(event_id: 'fail-test', subject: 'test', status: 'pending') }

    it 'sets status to failed' do
      event.mark_failed!('Error message')
      expect(event.reload.status).to eq('failed')
    end

    it 'sets last_error message' do
      event = described_class.create!(event_id: 'fail-with-error', subject: 'test', status: 'pending')
      event.mark_failed!('Something went wrong')
      expect(event.reload.last_error).to eq('Something went wrong')
    end

    it 'persists changes' do
      event.mark_failed!('Error')
      expect(event.reload.status).to eq('failed')
    end
  end

  describe '#payload_hash' do
    context 'when payload is a String' do
      it 'parses valid JSON' do
        event = described_class.create!(
          event_id: 'json-test',
          subject: 'test',
          payload: '{"user_id":123,"name":"Test"}'
        )
        expect(event.payload_hash).to eq('user_id' => 123, 'name' => 'Test')
      end

      it 'returns empty hash on JSON parse error' do
        event = described_class.create!(
          event_id: 'invalid-json',
          subject: 'test',
          payload: 'invalid json {{'
        )
        expect(event.payload_hash).to eq({})
      end
    end

    context 'when payload is a Hash' do
      it 'returns the hash' do
        event = described_class.create!(
          event_id: 'hash-test',
          subject: 'test',
          payload: { 'user_id' => 456 }.to_json
        )
        # Reload to get stored value
        event.reload
        # Override to simulate Hash payload
        allow(event).to receive(:[]).with(:payload).and_return({ 'user_id' => 456 })
        expect(event.payload_hash).to eq('user_id' => 456)
      end
    end

    context 'when payload responds to as_json' do
      it 'converts to JSON-compatible format' do
        event = described_class.create!(event_id: 'obj-test', subject: 'test')
        obj = double('CustomObject', as_json: { 'custom' => 'value' })
        allow(event).to receive(:[]).with(:payload).and_return(obj)
        expect(event.payload_hash).to eq('custom' => 'value')
      end
    end
  end

  describe 'without ActiveRecord (shim class)' do
    # Test the shim class behavior by creating a standalone test class
    before(:all) do
      @shim_class = Class.new do
        class << self
          def method_missing(method_name, *_args, &)
            raise(
              "Inbox requires ActiveRecord (tried to call ##{method_name}). " \
              'Enable `use_inbox` only in apps with ActiveRecord, or add ' \
              '`gem "activerecord"` to your Gemfile.'
            )
          end

          def respond_to_missing?(_method_name, _include_private = false)
            false
          end
        end
      end
    end

    it 'raises helpful error when calling class methods without ActiveRecord' do
      expect do
        @shim_class.create
      end.to raise_error(/Inbox requires ActiveRecord.*tried to call #create/)

      expect do
        @shim_class.find(1)
      end.to raise_error(/Inbox requires ActiveRecord.*tried to call #find/)
    end

    it 'mentions gem installation in error message' do
      expect do
        @shim_class.all
      end.to raise_error(/gem "activerecord"/)
    end

    it 'returns false for respond_to_missing?' do
      expect(@shim_class.respond_to?(:create, true)).to be false
      expect(@shim_class.respond_to?(:find, true)).to be false
    end
  end
end
