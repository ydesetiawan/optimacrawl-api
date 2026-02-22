# frozen_string_literal: true

class WebsiteDataSerializer
  include JSONAPI::Serializer

  attributes :url, :business_name, :license_status, :trenchless_technology,
             :emergency_service, :specific_equipment, :services_list,
             :price_mentions, :created_at, :updated_at
end
