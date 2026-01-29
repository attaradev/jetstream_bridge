# frozen_string_literal: true

class Organization < ApplicationRecord
  has_many :users, dependent: :destroy

  validates :name, presence: true
  validates :domain, presence: true, uniqueness: true

  # Track whether this record is being synced from another system
  attr_accessor :skip_publish

  # Publish events after transaction commits (only for locally created/updated records)
  after_commit :publish_created_event, on: :create, unless: :skip_publish
  after_commit :publish_updated_event, on: :update, unless: :skip_publish

  # Sync from System A events (idempotent upsert)
  def self.sync_from_event(event_payload)
    organization = find_or_initialize_by(id: event_payload[:id])
    organization.skip_publish = true # Prevent cyclic sync
    was_new_record = organization.new_record?

    organization.assign_attributes(
      name: event_payload[:name],
      domain: event_payload[:domain],
      active: event_payload[:active]
    )

    # Only update timestamps if they're newer (to handle out-of-order delivery)
    if organization.new_record? || organization.updated_at.nil? ||
       event_payload[:updated_at] > organization.updated_at
      organization.created_at = event_payload[:created_at] if organization.new_record?
      organization.updated_at = event_payload[:updated_at]
    else
      # Skip update if this is an older event
      Rails.logger.info "Skipping stale organization update for ID #{event_payload[:id]}"
      return organization
    end

    organization.save!
    reset_pk_sequence_if_supported if was_new_record
    Rails.logger.info "Synced organization ID #{organization.id}"
    organization
  end

  private

  def publish_created_event
    publish_event('created')
  end

  def publish_updated_event
    publish_event('updated')
  end

  def publish_event(event_type)
    result = JetstreamBridge.publish(
      resource_type: 'organization',
      event_type: event_type,
      resource_id: id.to_s,
      payload: {
        id: id,
        name: name,
        domain: domain,
        active: active,
        created_at: created_at,
        updated_at: updated_at
      }
    )

    if result.success?
      Rails.logger.info "Published organization.#{event_type} event: #{result.event_id}"
    else
      Rails.logger.error "Failed to publish organization.#{event_type}: #{result.error}"
    end
  end

  def self.reset_pk_sequence_if_supported
    connection.reset_pk_sequence!(table_name) if connection.respond_to?(:reset_pk_sequence!)
  end
end
