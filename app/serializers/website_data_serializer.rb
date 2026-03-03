# frozen_string_literal: true

class WebsiteDataSerializer
  include JSONAPI::Serializer

  attributes :url, :business_name, :license_status, :has_trenchless,
             :has_emergency_service, :equipment_brands_list, :services_list,
             :trenchless_technologies_list, :emergency_services_list,
             :created_at, :updated_at
end
