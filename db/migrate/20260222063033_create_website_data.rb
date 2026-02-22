class CreateWebsiteData < ActiveRecord::Migration[8.1]
  def change
    create_table :website_data do |t|
      t.string :url
      t.string :business_name
      t.string :license_status
      t.boolean :trenchless_technology
      t.boolean :emergency_service
      t.jsonb :specific_equipment
      t.jsonb :services_list
      t.jsonb :price_mentions

      t.timestamps
    end
  end
end
