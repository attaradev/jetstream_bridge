# frozen_string_literal: true

class SyncStatusController < ApplicationController
  # GET /sync_status
  def index
    status = {
      organizations_count: Organization.count,
      users_count: User.count,
      last_organization_sync: Organization.maximum(:updated_at),
      last_user_sync: User.maximum(:updated_at),
      jetstream_connected: JetstreamBridge.connected?,
      inbox_events_count: JetstreamBridge::InboxEvent.count,
      processed_events_count: JetstreamBridge::InboxEvent.where(status: 'processed').count,
      failed_events_count: JetstreamBridge::InboxEvent.where(status: 'failed').count,
      outbox_events_count: JetstreamBridge::OutboxEvent.count,
      sent_events_count: JetstreamBridge::OutboxEvent.where(status: 'sent').count,
      pending_events_count: JetstreamBridge::OutboxEvent.where(status: 'pending').count
    }

    render json: status
  end
end
