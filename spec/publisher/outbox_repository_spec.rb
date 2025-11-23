# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::OutboxRepository do
  let(:mock_model_class) { class_double('OutboxEvent') }
  let(:mock_record) { instance_double('OutboxEvent', save!: true, respond_to?: true, persisted?: false, new_record?: true) }
  let(:repository) { described_class.new(mock_model_class) }
  let(:event_id) { 'evt_123' }

  describe '#initialize' do
    it 'stores the model class' do
      expect(repository.instance_variable_get(:@klass)).to eq(mock_model_class)
    end
  end

  describe '#find_or_build' do
    before do
      allow(JetstreamBridge::ModelUtils).to receive(:find_or_init_by_best).and_return(mock_record)
    end

    it 'uses ModelUtils to find or initialize record' do
      expect(JetstreamBridge::ModelUtils).to receive(:find_or_init_by_best).with(
        mock_model_class,
        { event_id: event_id },
        { dedup_key: event_id }
      )
      repository.find_or_build(event_id)
    end

    it 'returns the record' do
      result = repository.find_or_build(event_id)
      expect(result).to eq(mock_record)
    end

    context 'when record is persisted' do
      let(:persisted_record) do
        instance_double('OutboxEvent',
                        persisted?: true,
                        new_record?: false,
                        respond_to?: true,
                        lock!: true)
      end

      before do
        allow(JetstreamBridge::ModelUtils).to receive(:find_or_init_by_best).and_return(persisted_record)
      end

      it 'locks the record' do
        expect(persisted_record).to receive(:lock!)
        repository.find_or_build(event_id)
      end

      context 'when record is deleted between find and lock' do
        let(:new_record) { instance_double('OutboxEvent', persisted?: false, new_record?: true) }

        before do
          allow(persisted_record).to receive(:lock!).and_raise(ActiveRecord::RecordNotFound)
          allow(mock_model_class).to receive(:new).and_return(new_record)
        end

        it 'creates a new record' do
          expect(mock_model_class).to receive(:new)
          repository.find_or_build(event_id)
        end

        it 'returns the new record' do
          result = repository.find_or_build(event_id)
          expect(result).to eq(new_record)
        end
      end
    end

    context 'when record does not respond to lock!' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:lock!).and_return(false)
        allow(mock_record).to receive(:persisted?).and_return(true)
        allow(mock_record).to receive(:new_record?).and_return(false)
      end

      it 'does not attempt to lock' do
        expect(mock_record).not_to receive(:lock!)
        repository.find_or_build(event_id)
      end
    end
  end

  describe '#already_sent?' do
    context 'when record has sent_at attribute' do
      it 'returns truthy if sent_at is present' do
        record = double('Record', sent_at: Time.now.utc, status: nil)
        allow(record).to receive(:respond_to?).with(:sent_at).and_return(true)
        allow(record).to receive(:respond_to?).with(:status).and_return(true)
        expect(repository.already_sent?(record)).to be_truthy
      end

      it 'returns falsey if sent_at is nil' do
        record = double('Record', sent_at: nil, status: nil)
        allow(record).to receive(:respond_to?).with(:sent_at).and_return(true)
        allow(record).to receive(:respond_to?).with(:status).and_return(true)
        expect(repository.already_sent?(record)).to be_falsey
      end
    end

    context 'when record has status attribute' do
      it 'returns truthy if status is sent' do
        record = double('Record', sent_at: nil, status: 'sent')
        allow(record).to receive(:respond_to?).with(:sent_at).and_return(true)
        allow(record).to receive(:respond_to?).with(:status).and_return(true)
        expect(repository.already_sent?(record)).to be_truthy
      end

      it 'returns falsey if status is not sent' do
        record = double('Record', sent_at: nil, status: 'pending')
        allow(record).to receive(:respond_to?).with(:sent_at).and_return(true)
        allow(record).to receive(:respond_to?).with(:status).and_return(true)
        expect(repository.already_sent?(record)).to be_falsey
      end
    end

    context 'when record has both sent_at and status' do
      it 'returns truthy if either is set' do
        record = double('Record', sent_at: Time.now.utc, status: 'pending')
        allow(record).to receive(:respond_to?).with(:sent_at).and_return(true)
        allow(record).to receive(:respond_to?).with(:status).and_return(true)
        expect(repository.already_sent?(record)).to be_truthy
      end
    end

    context 'when record has neither attribute set' do
      it 'returns falsey' do
        record = double('Record')
        allow(record).to receive(:respond_to?).and_return(false)
        expect(repository.already_sent?(record)).to be_falsey
      end
    end
  end

  describe '#persist_pre' do
    let(:subject) { 'test.subject' }
    let(:envelope) do
      {
        'event_id' => event_id,
        'resource_type' => 'User',
        'event_type' => 'created',
        'payload' => { 'id' => 1 }
      }
    end

    before do
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(Time).to receive(:now).and_return(Time.utc(2024, 1, 1, 12, 0, 0))
      allow(JetstreamBridge::ModelUtils).to receive(:json_dump) { |val| val }
      allow(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs)
      allow(mock_record).to receive(:respond_to?).with(:attempts).and_return(true)
      allow(mock_record).to receive(:respond_to?).with(:enqueued_at).and_return(true)
      allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(true)
      allow(mock_record).to receive(:attempts).and_return(0)
      allow(mock_record).to receive(:enqueued_at).and_return(nil)
    end

    it 'wraps in transaction' do
      expect(ActiveRecord::Base).to receive(:transaction).and_yield
      repository.persist_pre(mock_record, subject, envelope)
    end

    it 'assigns envelope attributes to record' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(
          event_id: event_id,
          subject: subject,
          status: 'publishing',
          last_error: nil
        )
      )
      repository.persist_pre(mock_record, subject, envelope)
    end

    it 'serializes payload' do
      expect(JetstreamBridge::ModelUtils).to receive(:json_dump).with(envelope)
      repository.persist_pre(mock_record, subject, envelope)
    end

    it 'creates headers with nats-msg-id' do
      expect(JetstreamBridge::ModelUtils).to receive(:json_dump)
        .with({ 'nats-msg-id' => event_id })
      repository.persist_pre(mock_record, subject, envelope)
    end

    it 'increments attempts' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(attempts: 1)
      )
      repository.persist_pre(mock_record, subject, envelope)
    end

    it 'saves the record' do
      expect(mock_record).to receive(:save!)
      repository.persist_pre(mock_record, subject, envelope)
    end

    context 'when record already has attempts' do
      before do
        allow(mock_record).to receive(:attempts).and_return(2)
      end

      it 'increments existing attempts' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_including(attempts: 3)
        )
        repository.persist_pre(mock_record, subject, envelope)
      end
    end

    context 'when record already has enqueued_at' do
      let(:existing_time) { Time.utc(2024, 1, 1, 10, 0, 0) }

      before do
        allow(mock_record).to receive(:enqueued_at).and_return(existing_time)
      end

      it 'preserves existing enqueued_at' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_including(enqueued_at: existing_time)
        )
        repository.persist_pre(mock_record, subject, envelope)
      end
    end

    context 'when record does not respond to attempts' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:attempts).and_return(false)
      end

      it 'does not include attempts in attributes' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_not_including(:attempts)
        )
        repository.persist_pre(mock_record, subject, envelope)
      end
    end

    context 'when record does not respond to enqueued_at' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:enqueued_at).and_return(false)
      end

      it 'does not include enqueued_at in attributes' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_not_including(:enqueued_at)
        )
        repository.persist_pre(mock_record, subject, envelope)
      end
    end

    context 'when record does not respond to updated_at' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(false)
      end

      it 'does not include updated_at in attributes' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_not_including(:updated_at)
        )
        repository.persist_pre(mock_record, subject, envelope)
      end
    end
  end

  describe '#persist_success' do
    before do
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(Time).to receive(:now).and_return(Time.utc(2024, 1, 1, 12, 0, 0))
      allow(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs)
      allow(mock_record).to receive(:respond_to?).with(:sent_at).and_return(true)
      allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(true)
    end

    it 'wraps in transaction' do
      expect(ActiveRecord::Base).to receive(:transaction).and_yield
      repository.persist_success(mock_record)
    end

    it 'marks status as sent' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(status: 'sent')
      )
      repository.persist_success(mock_record)
    end

    it 'sets sent_at timestamp' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(sent_at: Time.utc(2024, 1, 1, 12, 0, 0))
      )
      repository.persist_success(mock_record)
    end

    it 'saves the record' do
      expect(mock_record).to receive(:save!)
      repository.persist_success(mock_record)
    end

    context 'when record does not have sent_at' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:sent_at).and_return(false)
      end

      it 'does not include sent_at in attributes' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_not_including(:sent_at)
        )
        repository.persist_success(mock_record)
      end
    end

    context 'when record does not have updated_at' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(false)
      end

      it 'does not include updated_at in attributes' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_not_including(:updated_at)
        )
        repository.persist_success(mock_record)
      end
    end
  end

  describe '#persist_failure' do
    let(:error_message) { 'Connection timeout' }

    before do
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(Time).to receive(:now).and_return(Time.utc(2024, 1, 1, 12, 0, 0))
      allow(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs)
      allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(true)
    end

    it 'wraps in transaction' do
      expect(ActiveRecord::Base).to receive(:transaction).and_yield
      repository.persist_failure(mock_record, error_message)
    end

    it 'marks status as failed' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(status: 'failed')
      )
      repository.persist_failure(mock_record, error_message)
    end

    it 'stores error message' do
      expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
        mock_record,
        hash_including(last_error: error_message)
      )
      repository.persist_failure(mock_record, error_message)
    end

    it 'saves the record' do
      expect(mock_record).to receive(:save!)
      repository.persist_failure(mock_record, error_message)
    end

    context 'when record does not have updated_at' do
      before do
        allow(mock_record).to receive(:respond_to?).with(:updated_at).and_return(false)
      end

      it 'does not include updated_at in attributes' do
        expect(JetstreamBridge::ModelUtils).to receive(:assign_known_attrs).with(
          mock_record,
          hash_not_including(:updated_at)
        )
        repository.persist_failure(mock_record, error_message)
      end
    end
  end

  describe '#persist_exception' do
    let(:error) { StandardError.new('Something went wrong') }

    before do
      allow(repository).to receive(:persist_failure)
    end

    it 'calls persist_failure with formatted error' do
      expect(repository).to receive(:persist_failure).with(
        mock_record,
        'StandardError: Something went wrong'
      )
      repository.persist_exception(mock_record, error)
    end

    context 'when record is nil' do
      it 'does not raise error' do
        expect { repository.persist_exception(nil, error) }.not_to raise_error
      end

      it 'does not call persist_failure' do
        expect(repository).not_to receive(:persist_failure)
        repository.persist_exception(nil, error)
      end
    end

    context 'when persist_failure raises error' do
      before do
        allow(repository).to receive(:persist_failure).and_raise(ActiveRecord::RecordInvalid)
      end

      it 'rescues and does not re-raise' do
        expect { repository.persist_exception(mock_record, error) }.not_to raise_error
      end
    end
  end
end
