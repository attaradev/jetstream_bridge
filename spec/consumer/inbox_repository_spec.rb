# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::InboxRepository do
  let(:mock_model_class) { class_double('InboxEvent') }
  let(:mock_record) { instance_double('InboxEvent', save!: true, respond_to?: true, persisted?: false) }
  let(:repository) { described_class.new(mock_model_class) }

  let(:mock_message) do
    double('Message',
           event_id: 'evt_123',
           subject: 'test.subject',
           body_for_store: { 'data' => 'value' },
           headers: { 'key' => 'value' },
           stream: 'test_stream',
           seq: 42,
           deliveries: 1,
           now: Time.now.utc)
  end

  describe '#initialize' do
    it 'stores the model class' do
      expect(repository.instance_variable_get(:@klass)).to eq(mock_model_class)
    end
  end

  describe '#find_or_build' do
    context 'when model has event_id column' do
      before do
        allow(JetstreamBridge::ModelUtils).to receive(:has_columns?)
          .with(mock_model_class, :event_id).and_return(true)
        allow(mock_model_class).to receive(:find_or_initialize_by).and_return(mock_record)
        allow(mock_record).to receive(:persisted?).and_return(false)
      end

      it 'finds or initializes by event_id' do
        expect(mock_model_class).to receive(:find_or_initialize_by).with(event_id: 'evt_123')
        repository.find_or_build(mock_message)
      end

      it 'returns the record' do
        result = repository.find_or_build(mock_message)
        expect(result).to eq(mock_record)
      end

      context 'when record is persisted' do
        before do
          allow(mock_record).to receive(:persisted?).and_return(true)
          allow(mock_record).to receive(:lock!)
        end

        it 'locks the record to prevent concurrent processing' do
          expect(mock_record).to receive(:lock!)
          repository.find_or_build(mock_message)
        end
      end
    end

    context 'when model has stream_seq column but not event_id' do
      before do
        allow(JetstreamBridge::ModelUtils).to receive(:has_columns?)
          .with(mock_model_class, :event_id).and_return(false)
        allow(JetstreamBridge::ModelUtils).to receive(:has_columns?)
          .with(mock_model_class, :stream_seq).and_return(true)
        allow(mock_model_class).to receive(:find_or_initialize_by).and_return(mock_record)
        allow(mock_record).to receive(:persisted?).and_return(false)
      end

      it 'finds or initializes by stream_seq' do
        expect(mock_model_class).to receive(:find_or_initialize_by).with(stream_seq: 42)
        repository.find_or_build(mock_message)
      end
    end

    context 'when model has neither event_id nor stream_seq' do
      before do
        allow(JetstreamBridge::ModelUtils).to receive(:has_columns?).and_return(false)
        allow(mock_model_class).to receive(:new).and_return(mock_record)
      end

      it 'creates a new record' do
        expect(mock_model_class).to receive(:new)
        repository.find_or_build(mock_message)
      end
    end
  end

  describe '#already_processed?' do
    context 'when record has processed_at attribute' do
      it 'returns truthy if processed_at is present' do
        record = double('Record', processed_at: Time.now.utc)
        allow(record).to receive(:respond_to?).with(:processed_at).and_return(true)
        expect(repository.already_processed?(record)).to be_truthy
      end

      it 'returns falsey if processed_at is nil' do
        record = double('Record', processed_at: nil)
        allow(record).to receive(:respond_to?).with(:processed_at).and_return(true)
        expect(repository.already_processed?(record)).to be_falsey
      end

      it 'returns truthy if processed_at is blank string' do
        record = double('Record', processed_at: '')
        allow(record).to receive(:respond_to?).with(:processed_at).and_return(true)
        # Empty string is truthy in Ruby, so this returns the empty string (truthy)
        expect(repository.already_processed?(record)).to be_truthy
      end
    end

    context 'when record does not have processed_at attribute' do
      it 'returns falsey' do
        record = double('Record')
        allow(record).to receive(:respond_to?).with(:processed_at).and_return(false)
        expect(repository.already_processed?(record)).to be_falsey
      end
    end
  end

  describe '#persist_pre' do
    let(:now) { Time.now.utc }
    let(:mock_message) do
      double('Message',
             event_id: 'evt_123',
             subject: 'test.subject',
             body_for_store: { 'data' => 'value' },
             headers: { 'key' => 'value' },
             stream: 'test_stream',
             seq: 42,
             deliveries: 1,
             now: now)
    end

    before do
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(JetstreamBridge::ModelUtils).to receive(:json_dump) { |val| val }
      allow(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs)
      allow(mock_record).to receive(:respond_to?).with(:received_at).and_return(true)
      allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(true)
      allow(mock_record).to receive(:received_at).and_return(nil)
    end

    it 'wraps in transaction' do
      expect(ActiveRecord::Base).to receive(:transaction).and_yield
      repository.persist_pre(mock_record, mock_message)
    end

    it 'assigns message attributes to record' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(
          event_id: 'evt_123',
          subject: 'test.subject',
          stream: 'test_stream',
          stream_seq: 42,
          deliveries: 1,
          status: 'processing',
          last_error: nil
        )
      )
      repository.persist_pre(mock_record, mock_message)
    end

    it 'serializes payload and headers' do
      expect(JetstreamBridge::ModelUtils).to receive(:json_dump).with({ 'data' => 'value' })
      expect(JetstreamBridge::ModelUtils).to receive(:json_dump).with({ 'key' => 'value' })
      repository.persist_pre(mock_record, mock_message)
    end

    it 'saves the record' do
      expect(mock_record).to receive(:save!)
      repository.persist_pre(mock_record, mock_message)
    end

    context 'when record already has received_at' do
      before do
        allow(mock_record).to receive(:received_at).and_return(Time.now.utc - 100)
      end

      it 'preserves existing received_at' do
        existing_time = mock_record.received_at
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_including(received_at: existing_time)
        )
        repository.persist_pre(mock_record, mock_message)
      end
    end

    context 'when record does not respond to received_at' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:received_at).and_return(false)
      end

      it 'sets received_at to nil' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_including(received_at: nil)
        )
        repository.persist_pre(mock_record, mock_message)
      end
    end
  end

  describe '#persist_post' do
    before do
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(Time).to receive(:now).and_return(Time.utc(2024, 1, 1, 12, 0, 0))
      allow(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs)
      allow(mock_record).to receive(:respond_to?).with(:processed_at).and_return(true)
      allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(true)
    end

    it 'wraps in transaction' do
      expect(ActiveRecord::Base).to receive(:transaction).and_yield
      repository.persist_post(mock_record)
    end

    it 'marks status as processed' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(status: 'processed')
      )
      repository.persist_post(mock_record)
    end

    it 'sets processed_at timestamp' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(processed_at: Time.utc(2024, 1, 1, 12, 0, 0))
      )
      repository.persist_post(mock_record)
    end

    it 'saves the record' do
      expect(mock_record).to receive(:save!)
      repository.persist_post(mock_record)
    end

    context 'when record does not have processed_at' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:processed_at).and_return(false)
      end

      it 'sets processed_at to nil' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_including(processed_at: nil)
        )
        repository.persist_post(mock_record)
      end
    end
  end

  describe '#persist_failure' do
    let(:error) { StandardError.new('Something went wrong') }

    before do
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(Time).to receive(:now).and_return(Time.utc(2024, 1, 1, 12, 0, 0))
      allow(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs)
      allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(true)
    end

    it 'wraps in transaction' do
      expect(ActiveRecord::Base).to receive(:transaction).and_yield
      repository.persist_failure(mock_record, error)
    end

    it 'marks status as failed' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(status: 'failed')
      )
      repository.persist_failure(mock_record, error)
    end

    it 'stores error message' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(last_error: 'StandardError: Something went wrong')
      )
      repository.persist_failure(mock_record, error)
    end

    it 'saves the record' do
      expect(mock_record).to receive(:save!)
      repository.persist_failure(mock_record, error)
    end

    context 'when record is nil' do
      it 'does not raise error' do
        expect { repository.persist_failure(nil, error) }.not_to raise_error
      end

      it 'does not attempt to save' do
        expect(ActiveRecord::Base).not_to receive(:transaction)
        repository.persist_failure(nil, error)
      end
    end

    context 'when save fails' do
      before do
        allow(mock_record).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
      end

      it 'rescues and does not re-raise' do
        expect { repository.persist_failure(mock_record, error) }.not_to raise_error
      end
    end
  end
end
