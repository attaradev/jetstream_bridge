# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/core/consumer_mode_resolver'

RSpec.describe JetstreamBridge::ConsumerModeResolver do
  def with_env(env)
    old = {}
    env.each_key { |k| old[k] = ENV.fetch(k, nil) }
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    env.each_key { |k| old[k].nil? ? ENV.delete(k) : ENV[k] = old[k] }
  end

  describe '.resolve' do
    it 'returns explicit override when provided' do
      expect(described_class.resolve(app_name: 'app', override: :push)).to eq(:push)
    end

    it 'derives from CONSUMER_MODES map' do
      with_env('CONSUMER_MODES' => 'app:push') do
        expect(described_class.resolve(app_name: 'app')).to eq(:push)
      end
    end

    it 'derives from per-app env' do
      with_env('CONSUMER_MODE_APP' => 'push') do
        expect(described_class.resolve(app_name: 'app')).to eq(:push)
      end
    end

    it 'derives from shared env' do
      with_env('CONSUMER_MODE' => 'push') do
        expect(described_class.resolve(app_name: 'app')).to eq(:push)
      end
    end

    it 'falls back to provided fallback when nothing else set' do
      expect(described_class.resolve(app_name: 'app', fallback: :pull)).to eq(:pull)
    end

    it 'normalizes string values' do
      expect(described_class.normalize('push')).to eq(:push)
    end

    it 'raises on invalid mode' do
      expect { described_class.resolve(app_name: 'app', override: :invalid) }.to raise_error(ArgumentError)
    end
  end
end
