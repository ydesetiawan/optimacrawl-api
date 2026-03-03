class RenameAndAddTrenchlessColumns < ActiveRecord::Migration[8.1]
  def change
    rename_column :website_data, :trenchless_technology, :has_trenchless
    add_column :website_data, :trenchless_technologies, :jsonb
  end
end
