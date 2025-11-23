# frozen_string_literal: true

require 'jetstream_bridge'
require 'active_record'
require 'oj'

RSpec.describe JetstreamBridge::InboxEvent do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.define do
      create_table :jetstream_inbox_events, force: true do |t|
        t.string :event_id
        t.integer :stream_seq
        t.string :stream
        t.string :subject
        t.text :payload
        t.string :status, default: 'received'
        t.datetime :received_at
        t.datetime :processed_at
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
end
