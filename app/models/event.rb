# == Schema Information
#
# Table name: events
#
#  id              :bigint           not null, primary key
#  data            :jsonb
#  event_time      :datetime         not null
#  eventable_type  :string
#  type            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  eventable_id    :bigint
#  organization_id :bigint
#  user_id         :bigint
#
class Event < ApplicationRecord
  scope :for_organization, ->(organization_id) { where(organization_id: organization_id).order(:event_time) }
  scope :without_snapshots, -> { where("type != 'SnapshotEvent'") }

  serialize :data, EventTypes::StructCoder.new(EventTypes::InventoryPayload)

  belongs_to :eventable, polymorphic: true
  belongs_to :user, optional: true

  before_create do
    self.user_id = PaperTrail.request&.whodunnit
  end

  # Returns the most recent "usable" snapshot. A snapshot is unusable if there is another event
  # that was originally made before the snapshot, but was later updated/edited after the snapshot
  # (i.e. there is a correction event whose event_time is before the snapshot, but whose
  # updated_at time is after it).
  # In this case, the values in the snapshot can't be used to start the inventory because they
  # wouldn't reflect the updates.
  # There should always be at least one usable snapshot since the very first event we have in the
  # DB for any organization should be a SnapshotEvent.
  # @param organization_id [Integer]
  # @return [SnapshotEvent]
  def self.most_recent_snapshot(organization_id)
    query = <<-SQL
        select *
        FROM events as snapshots
        WHERE type='SnapshotEvent' AND organization_id=$1
        AND NOT EXISTS (
            SELECT id
            FROM events
            WHERE type != 'SnapshotEvent'
            AND event_time < snapshots.event_time AND updated_at > snapshots.event_time
        )
        ORDER BY event_time DESC
        LIMIT 1
    SQL
    SnapshotEvent.find_by_sql(query, [organization_id]).first
  end

  after_create_commit do
    inventory = InventoryAggregate.inventory_for(organization_id)
    diffs = EventDiffer.check_difference(inventory)
    if diffs.any?
      InventoryDiscrepancy.create!(
        event_id: id,
        organization_id: organization_id,
        diff: diffs
      )
    end
  end
end
