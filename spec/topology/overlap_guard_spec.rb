# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::OverlapGuard do
  let(:mock_jts) { double('NATS::JetStream') }
  let(:mock_nc) { double('NATS::Client') }
  let(:target_stream) { 'target_stream' }

  before do
    allow(mock_jts).to receive(:nc).and_return(mock_nc)
  end

  describe '.check!' do
    context 'when no conflicts exist' do
      before do
        allow(described_class).to receive(:overlaps).and_return([])
      end

      it 'does not raise error' do
        expect do
          described_class.check!(mock_jts, target_stream, ['test.subject'])
        end.not_to raise_error
      end
    end

    context 'when conflicts exist' do
      let(:conflicts) do
        [
          { name: 'other_stream', pairs: [['test.subject', 'test.*']] }
        ]
      end

      before do
        allow(described_class).to receive(:overlaps).and_return(conflicts)
      end

      it 'raises error with conflict details' do
        expect do
          described_class.check!(mock_jts, target_stream, ['test.subject'])
        end.to raise_error(/Overlapping subjects for stream target_stream/)
      end

      it 'includes conflicting stream name in error' do
        expect do
          described_class.check!(mock_jts, target_stream, ['test.subject'])
        end.to raise_error(/other_stream/)
      end

      it 'includes conflicting subject pairs in error' do
        expect do
          described_class.check!(mock_jts, target_stream, ['test.subject'])
        end.to raise_error(/test\.subject × test\.\*/)
      end
    end
  end

  describe '.overlaps' do
    let(:streams_data) do
      [
        { name: 'stream_one', subjects: ['one.*'] },
        { name: target_stream, subjects: ['target.*'] },
        { name: 'stream_two', subjects: ['two.>'] }
      ]
    end

    before do
      allow(described_class).to receive(:list_streams_with_subjects).and_return(streams_data)
    end

    context 'when no overlaps exist' do
      it 'returns empty array' do
        result = described_class.overlaps(mock_jts, target_stream, ['three.subject'])
        expect(result).to be_empty
      end
    end

    context 'when overlaps exist with other streams' do
      it 'detects wildcard overlaps' do
        result = described_class.overlaps(mock_jts, target_stream, ['one.test'])
        expect(result).not_to be_empty
        expect(result.first[:name]).to eq('stream_one')
        expect(result.first[:pairs]).to include(['one.test', 'one.*'])
      end

      it 'detects greedy wildcard overlaps' do
        result = described_class.overlaps(mock_jts, target_stream, ['two.test.deep'])
        expect(result).not_to be_empty
        expect(result.first[:name]).to eq('stream_two')
        expect(result.first[:pairs]).to include(['two.test.deep', 'two.>'])
      end

      it 'ignores own stream' do
        result = described_class.overlaps(mock_jts, target_stream, ['target.test'])
        expect(result).to be_empty
      end
    end

    context 'with multiple conflicts' do
      let(:streams_data) do
        [
          { name: 'stream_one', subjects: ['test.*'] },
          { name: 'stream_two', subjects: ['test.>'] }
        ]
      end

      it 'returns all conflicts' do
        result = described_class.overlaps(mock_jts, target_stream, ['test.subject'])
        expect(result.size).to eq(2)
        expect(result.map { |c| c[:name] }).to contain_exactly('stream_one', 'stream_two')
      end
    end

    it 'normalizes and deduplicates subjects' do
      allow(JetstreamBridge::SubjectMatcher).to receive(:overlap?).and_return(false)
      described_class.overlaps(mock_jts, target_stream, ['test', 'test', :test])
      expect(JetstreamBridge::SubjectMatcher).to have_received(:overlap?).with('test', anything).at_least(:once)
    end
  end

  describe '.partition_allowed' do
    let(:desired_subjects) { ['allowed.one', 'blocked.one', 'allowed.two'] }
    let(:conflicts) do
      [
        { name: 'other_stream', pairs: [['blocked.one', 'blocked.*']] }
      ]
    end

    before do
      allow(described_class).to receive(:overlaps).and_return(conflicts)
    end

    it 'returns array of [allowed, blocked]' do
      allowed, blocked = described_class.partition_allowed(mock_jts, target_stream, desired_subjects)
      expect(allowed).to contain_exactly('allowed.one', 'allowed.two')
      expect(blocked).to contain_exactly('blocked.one')
    end

    context 'when all subjects are allowed' do
      before do
        allow(described_class).to receive(:overlaps).and_return([])
      end

      it 'returns all subjects as allowed' do
        allowed, blocked = described_class.partition_allowed(mock_jts, target_stream, desired_subjects)
        expect(allowed).to match_array(desired_subjects)
        expect(blocked).to be_empty
      end
    end

    context 'when all subjects are blocked' do
      let(:all_blocked_conflicts) do
        [
          { name: 'stream_one', pairs: [['allowed.one', '*.one']] },
          { name: 'stream_two', pairs: [['allowed.two', '*.two']] },
          { name: 'stream_three', pairs: [['blocked.one', 'blocked.*']] }
        ]
      end

      before do
        allow(described_class).to receive(:overlaps).and_return(all_blocked_conflicts)
      end

      it 'returns all subjects as blocked' do
        allowed, blocked = described_class.partition_allowed(mock_jts, target_stream, desired_subjects)
        expect(allowed).to be_empty
        expect(blocked).to contain_exactly('allowed.one', 'allowed.two', 'blocked.one')
      end
    end
  end

  describe '.allowed_subjects' do
    before do
      allow(described_class).to receive(:partition_allowed).and_return([['allowed'], ['blocked']])
    end

    it 'returns only the allowed subjects' do
      result = described_class.allowed_subjects(mock_jts, target_stream, ['test'])
      expect(result).to eq(['allowed'])
    end
  end

  describe '.list_streams_with_subjects' do
    let(:stream_names) { %w[stream_one stream_two] }
    let(:info_one) { double('StreamInfo', config: double(subjects: ['one.*'])) }
    let(:info_two) { double('StreamInfo', config: double(subjects: ['two.>'])) }

    before do
      # Clear cache before each test to avoid interference
      described_class.clear_cache!
      allow(described_class).to receive(:list_stream_names).and_return(stream_names)
      allow(mock_jts).to receive(:stream_info).with('stream_one').and_return(info_one)
      allow(mock_jts).to receive(:stream_info).with('stream_two').and_return(info_two)
    end

    it 'returns array of stream data with subjects' do
      result = described_class.list_streams_with_subjects(mock_jts)
      expect(result).to contain_exactly(
        { name: 'stream_one', subjects: ['one.*'] },
        { name: 'stream_two', subjects: ['two.>'] }
      )
    end

    it 'handles nil subjects' do
      allow(mock_jts).to receive(:stream_info).with('stream_one')
                                              .and_return(double('StreamInfo', config: double(subjects: nil)))
      result = described_class.list_streams_with_subjects(mock_jts)
      expect(result.first[:subjects]).to eq([])
    end
  end

  describe '.list_stream_names' do
    let(:mock_msg) { double('Message', data: response_json) }

    context 'with single page of results' do
      let(:response_json) do
        Oj.dump({ 'total' => 2, 'streams' => [{ 'name' => 'stream_one' }, { 'name' => 'stream_two' }] })
      end

      before do
        allow(mock_nc).to receive(:request).and_return(mock_msg)
      end

      it 'returns all stream names' do
        result = described_class.list_stream_names(mock_jts)
        expect(result).to contain_exactly('stream_one', 'stream_two')
      end

      it 'makes API request with correct subject' do
        expect(mock_nc).to receive(:request).with('$JS.API.STREAM.NAMES', anything)
        described_class.list_stream_names(mock_jts)
      end
    end

    context 'with multiple pages of results' do
      before do
        @call_count = 0
        allow(mock_nc).to receive(:request) do
          @call_count += 1
          data = if @call_count == 1
                   Oj.dump({ 'total' => 3, 'streams' => [{ 'name' => 'stream_one' }, { 'name' => 'stream_two' }] })
                 else
                   Oj.dump({ 'total' => 3, 'streams' => [{ 'name' => 'stream_three' }] })
                 end
          double('Message', data: data)
        end
      end

      it 'makes multiple requests to fetch all streams' do
        result = described_class.list_stream_names(mock_jts)
        expect(result).to contain_exactly('stream_one', 'stream_two', 'stream_three')
        expect(@call_count).to eq(2)
      end

      it 'uses offset for pagination' do
        expect(mock_nc).to receive(:request)
          .with('$JS.API.STREAM.NAMES', Oj.dump({ offset: 0 }, mode: :compat))
          .and_return(double('Message', data: Oj.dump({ 'total' => 3, 'streams' => [{ 'name' => 'one' }, { 'name' => 'two' }] })))
        expect(mock_nc).to receive(:request)
          .with('$JS.API.STREAM.NAMES', Oj.dump({ offset: 2 }, mode: :compat))
          .and_return(double('Message', data: Oj.dump({ 'total' => 3, 'streams' => [{ 'name' => 'three' }] })))

        described_class.list_stream_names(mock_jts)
      end
    end

    context 'with safety limit' do
      before do
        allow(mock_nc).to receive(:request) do
          double('Message', data: Oj.dump({ 'total' => 1000, 'streams' => [{ 'name' => 'stream' }] }))
        end
      end

      it 'stops after max iterations' do
        described_class.list_stream_names(mock_jts)
        expect(mock_nc).to have_received(:request).at_most(100).times
      end
    end

    context 'with empty response' do
      let(:response_json) do
        Oj.dump({ 'total' => 0, 'streams' => [] })
      end

      before do
        allow(mock_nc).to receive(:request).and_return(mock_msg)
      end

      it 'returns empty array' do
        result = described_class.list_stream_names(mock_jts)
        expect(result).to be_empty
      end
    end

    context 'with nil stream names' do
      it 'filters out nil stream names' do
        response_data = Oj.dump({ 'total' => 1, 'streams' => [{ 'name' => 'stream_one' }, { 'name' => nil }] })
        msg = double('Message', data: response_data)
        allow(mock_nc).to receive(:request).and_return(msg)

        result = described_class.list_stream_names(mock_jts)
        expect(result).to eq(['stream_one'])
      end
    end
  end

  describe '.js_api_request' do
    let(:mock_msg) { double('Message', data: '{"result": "success"}') }
    let(:subject) { '$JS.API.STREAM.LIST' }
    let(:payload) { { offset: 0 } }

    before do
      allow(mock_nc).to receive(:request).and_return(mock_msg)
    end

    it 'makes request to NATS client' do
      expect(mock_nc).to receive(:request).with(subject, Oj.dump(payload, mode: :compat))
      described_class.js_api_request(mock_jts, subject, payload)
    end

    it 'parses JSON response' do
      result = described_class.js_api_request(mock_jts, subject, payload)
      expect(result).to eq({ 'result' => 'success' })
    end

    it 'handles empty payload' do
      expect(mock_nc).to receive(:request).with(subject, '{}')
      described_class.js_api_request(mock_jts, subject)
    end
  end

  describe '.conflict_message' do
    let(:conflicts) do
      [
        {
          name: 'stream_one',
          pairs: [['test.one', 'test.*'], ['test.two', 'test.*']]
        },
        {
          name: 'stream_two',
          pairs: [['other.subject', 'other.>']]
        }
      ]
    end

    it 'formats error message with stream name' do
      message = described_class.conflict_message(target_stream, conflicts)
      expect(message).to include('target_stream')
    end

    it 'includes all conflicting streams' do
      message = described_class.conflict_message(target_stream, conflicts)
      expect(message).to include('stream_one')
      expect(message).to include('stream_two')
    end

    it 'includes all subject pairs' do
      message = described_class.conflict_message(target_stream, conflicts)
      expect(message).to include('test.one × test.*')
      expect(message).to include('test.two × test.*')
      expect(message).to include('other.subject × other.>')
    end
  end

end
