class RenameSpecificEquipmentToEquipmentBrandsList < ActiveRecord::Migration[8.1]
  def change
    rename_column :website_data, :specific_equipment, :equipment_brands_list
  end
end
