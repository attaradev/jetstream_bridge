# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge do
  describe '.ensure_topology!' do
    it 'connects and returns the jetstream context' do
      jts = double('jetstream')
      expect(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
      expect(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      expect(described_class.ensure_topology!).to eq(jts)
    end
  end

  describe '.ensure_topology?' do
    it 'delegates to ensure_topology! and returns boolean' do
      jts = double('jetstream')
      expect(described_class).to receive(:ensure_topology!).and_return(jts)
      expect(described_class.ensure_topology?).to eq(true)
    end
  end
end
