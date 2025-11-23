# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge::BatchPublisher do
  let(:publisher) { double('publisher') }
  subject(:batch) { described_class.new(publisher) }

  describe '#add' do
    it 'adds events to the batch' do
      expect do
        batch.add(event_type: 'user.created', payload: { id: 1 })
      end.to change(batch, :size).from(0).to(1)
    end

    it 'returns self for chaining' do
      result = batch.add(event_type: 'user.created', payload: { id: 1 })
      expect(result).to eq(batch)
    end

    it 'allows method chaining' do
      batch
        .add(event_type: 'user.created', payload: { id: 1 })
        .add(event_type: 'user.created', payload: { id: 2 })

      expect(batch.size).to eq(2)
    end
  end

  describe '#size' do
    it 'returns 0 for empty batch' do
      expect(batch.size).to eq(0)
    end

    it 'returns count of added events' do
      batch.add(event_type: 'user.created', payload: { id: 1 })
      batch.add(event_type: 'user.created', payload: { id: 2 })
      expect(batch.size).to eq(2)
    end

    it 'has count alias' do
      batch.add(event_type: 'user.created', payload: { id: 1 })
      expect(batch.count).to eq(1)
    end

    it 'has length alias' do
      batch.add(event_type: 'user.created', payload: { id: 1 })
      expect(batch.length).to eq(1)
    end
  end

  describe '#empty?' do
    it 'returns true for empty batch' do
      expect(batch.empty?).to be(true)
    end

    it 'returns false when events are added' do
      batch.add(event_type: 'user.created', payload: { id: 1 })
      expect(batch.empty?).to be(false)
    end
  end

  describe '#publish' do
    let(:success_result) do
      JetstreamBridge::Models::PublishResult.new(
        success: true,
        event_id: 'evt-1',
        subject: 'test.subject'
      )
    end

    let(:failure_result) do
      JetstreamBridge::Models::PublishResult.new(
        success: false,
        event_id: 'evt-2',
        subject: 'test.subject',
        error: StandardError.new('Publish failed')
      )
    end

    context 'with all successful publishes' do
      before do
        allow(publisher).to receive(:publish).and_return(success_result)
        batch.add(event_type: 'user.created', payload: { id: 1 })
        batch.add(event_type: 'user.created', payload: { id: 2 })
      end

      it 'returns BatchResult' do
        result = batch.publish
        expect(result).to be_a(JetstreamBridge::BatchPublisher::BatchResult)
      end

      it 'counts all successes' do
        result = batch.publish
        expect(result.successful_count).to eq(2)
        expect(result.failed_count).to eq(0)
      end

      it 'reports overall success' do
        result = batch.publish
        expect(result.success?).to be(true)
        expect(result.failure?).to be(false)
      end

      it 'clears batch after publish' do
        batch.publish
        expect(batch.size).to eq(0)
      end
    end

    context 'with all failed publishes' do
      before do
        allow(publisher).to receive(:publish).and_return(failure_result)
        batch.add(event_type: 'user.created', payload: { id: 1 })
        batch.add(event_type: 'user.created', payload: { id: 2 })
      end

      it 'counts all failures' do
        result = batch.publish
        expect(result.successful_count).to eq(0)
        expect(result.failed_count).to eq(2)
      end

      it 'reports overall failure' do
        result = batch.publish
        expect(result.success?).to be(false)
        expect(result.failure?).to be(true)
      end

      it 'collects error details' do
        result = batch.publish
        expect(result.errors.size).to eq(2)
        expect(result.errors.first).to have_key(:event_id)
        expect(result.errors.first).to have_key(:error)
      end
    end

    context 'with partial success' do
      before do
        allow(publisher).to receive(:publish).and_return(success_result, failure_result)
        batch.add(event_type: 'user.created', payload: { id: 1 })
        batch.add(event_type: 'user.created', payload: { id: 2 })
      end

      it 'counts both successes and failures' do
        result = batch.publish
        expect(result.successful_count).to eq(1)
        expect(result.failed_count).to eq(1)
      end

      it 'reports partial success' do
        result = batch.publish
        expect(result.partial_success?).to be(true)
        expect(result.success?).to be(false)
        expect(result.failure?).to be(true)
      end
    end

    context 'with exceptions during publish' do
      before do
        allow(publisher).to receive(:publish).and_raise(StandardError.new('Connection error'))
        batch.add(event_type: 'user.created', payload: { id: 1 })
      end

      it 'handles exceptions gracefully' do
        expect { batch.publish }.not_to raise_error
      end

      it 'returns failure result for exceptions' do
        result = batch.publish
        expect(result.failed_count).to eq(1)
        expect(result.errors.first[:error]).to be_a(StandardError)
      end
    end

    context 'with empty batch' do
      it 'returns successful empty result' do
        result = batch.publish
        expect(result.success?).to be(true)
        expect(result.successful_count).to eq(0)
        expect(result.failed_count).to eq(0)
      end
    end
  end

  describe 'BatchResult' do
    let(:results) do
      [
        JetstreamBridge::Models::PublishResult.new(success: true, event_id: 'evt-1', subject: 'test'),
        JetstreamBridge::Models::PublishResult.new(success: true, event_id: 'evt-2', subject: 'test'),
        JetstreamBridge::Models::PublishResult.new(
          success: false,
          event_id: 'evt-3',
          subject: 'test',
          error: StandardError.new('Failed')
        )
      ]
    end

    subject(:batch_result) { described_class::BatchResult.new(results) }

    describe '#to_h' do
      it 'converts to hash' do
        hash = batch_result.to_h
        expect(hash).to include(
          successful_count: 2,
          failed_count: 1,
          total_count: 3
        )
      end

      it 'includes errors' do
        hash = batch_result.to_h
        expect(hash[:errors]).to be_an(Array)
        expect(hash[:errors].size).to eq(1)
      end
    end

    describe 'immutability' do
      it 'is frozen' do
        expect(batch_result).to be_frozen
      end
    end
  end
end
