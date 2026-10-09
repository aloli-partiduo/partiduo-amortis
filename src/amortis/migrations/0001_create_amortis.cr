# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension des immobilisations et des amortissements :
# immobilisations et composants, sorties, dépréciations, écritures
# d'inventaire et leurs montants par immobilisation, réglages.
#
# Intégrité en base : modes, sortes et statuts contrôlés ; valeur brute
# positive, valeur résiduelle entre zéro et la valeur brute ; durée
# positive pour un mode amortissable ; mise en service après l'acquisition ;
# un composant ne porte pas lui-même de composant (vérifié par le contrat) ;
# numéro d'inventaire unique sans casse ; dépréciation non nulle ; une
# immobilisation n'a qu'une sortie ; prix de rebut nul. Les liens vers le
# cœur (écritures, lignes, journal, exercice) sont des identifiants relus par
# le contrat, sans clé étrangère (D-AMO-004).
class Migration::Amortis::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE amortis_asset
        ADD CONSTRAINT amortis_asset_code_check CHECK (btrim(code) <> ''),
        ADD CONSTRAINT amortis_asset_label_check CHECK (btrim(label) <> ''),
        ADD CONSTRAINT amortis_asset_method_check CHECK (method IN ('linear', 'degressive', 'none')),
        ADD CONSTRAINT amortis_asset_fiscal_method_check CHECK (fiscal_method IN ('same', 'linear', 'degressive')),
        ADD CONSTRAINT amortis_asset_gross_check CHECK (gross_value > 0),
        ADD CONSTRAINT amortis_asset_residual_check CHECK (residual_value >= 0 AND residual_value < gross_value),
        ADD CONSTRAINT amortis_asset_life_check CHECK ((method = 'none') OR (life_months BETWEEN 1 AND 1200)),
        ADD CONSTRAINT amortis_asset_fiscal_life_check CHECK (fiscal_method = 'same' OR fiscal_life_months BETWEEN 1 AND 1200),
        ADD CONSTRAINT amortis_asset_service_check CHECK (in_service_on IS NULL OR in_service_on >= acquired_on),
        ADD CONSTRAINT amortis_asset_parent_fk FOREIGN KEY (parent_id) REFERENCES amortis_asset (id) ON DELETE CASCADE,
        ADD CONSTRAINT amortis_asset_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX amortis_asset_code_unique ON amortis_asset (lower(code))",
     "DROP INDEX IF EXISTS amortis_asset_code_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE amortis_disposal
        ADD CONSTRAINT amortis_disposal_kind_check CHECK (kind IN ('sale', 'scrap')),
        ADD CONSTRAINT amortis_disposal_price_check CHECK (price >= 0 AND (kind = 'sale' OR price = 0)),
        ADD CONSTRAINT amortis_disposal_asset_fk FOREIGN KEY (asset_id) REFERENCES amortis_asset (id) ON DELETE CASCADE,
        ADD CONSTRAINT amortis_disposal_parent_fk FOREIGN KEY (parent_disposal_id) REFERENCES amortis_disposal (id) ON DELETE CASCADE,
        ADD CONSTRAINT amortis_disposal_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE amortis_impairment
        ADD CONSTRAINT amortis_impairment_amount_check CHECK (amount <> 0),
        ADD CONSTRAINT amortis_impairment_asset_fk FOREIGN KEY (asset_id) REFERENCES amortis_asset (id) ON DELETE CASCADE,
        ADD CONSTRAINT amortis_impairment_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE amortis_posting
        ADD CONSTRAINT amortis_posting_kind_check CHECK (kind IN ('depreciation', 'impairment', 'disposal')),
        ADD CONSTRAINT amortis_posting_status_check CHECK (status IN ('posted', 'cancelled')),
        ADD CONSTRAINT amortis_posting_period_check CHECK (exercise_start <= exercise_end),
        ADD CONSTRAINT amortis_posting_reversal_check CHECK ((status = 'cancelled') = (reversal_entry_id IS NOT NULL)),
        ADD CONSTRAINT amortis_posting_asset_fk FOREIGN KEY (asset_id) REFERENCES amortis_asset (id) ON DELETE RESTRICT,
        ADD CONSTRAINT amortis_posting_impairment_fk FOREIGN KEY (impairment_id) REFERENCES amortis_impairment (id) ON DELETE RESTRICT,
        ADD CONSTRAINT amortis_posting_disposal_fk FOREIGN KEY (disposal_id) REFERENCES amortis_disposal (id) ON DELETE RESTRICT,
        ADD CONSTRAINT amortis_posting_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE amortis_posting_line
        ADD CONSTRAINT amortis_posting_line_posting_fk FOREIGN KEY (posting_id) REFERENCES amortis_posting (id) ON DELETE CASCADE,
        ADD CONSTRAINT amortis_posting_line_asset_fk FOREIGN KEY (asset_id) REFERENCES amortis_asset (id) ON DELETE RESTRICT
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE amortis_setting
        ADD CONSTRAINT amortis_setting_day_count_check CHECK (day_count IN ('actual', '360'))
      SQL
  ]

  def plan
    create_table :amortis_asset do
      column :id, :big_int, primary_key: true, auto: true
      column :parent_id, :big_int, null: true, index: true
      column :code, :string, max_size: 30
      column :label, :string, max_size: 255
      column :card_code, :string, max_size: 64, default: ""
      column :asset_account, :string, max_size: 40
      column :depreciation_account, :string, max_size: 40, default: ""
      column :impairment_account, :string, max_size: 40, default: ""
      column :expense_account, :string, max_size: 40, default: ""
      column :acquired_on, :date
      column :in_service_on, :date, null: true
      column :gross_value, :decimal, max_digits: 20, decimal_places: 2
      column :residual_value, :decimal, max_digits: 20, decimal_places: 2, default: 0
      column :method, :string, max_size: 16, default: "linear"
      column :life_months, :int, default: 0
      column :fiscal_method, :string, max_size: 16, default: "same"
      column :fiscal_life_months, :int, null: true
      column :new_asset, :bool, default: true
      column :entry_id, :big_int, null: true
      column :entry_line_id, :big_int, null: true, index: true
      column :notes, :text, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :amortis_disposal do
      column :id, :big_int, primary_key: true, auto: true
      column :asset_id, :big_int, unique: true
      column :parent_disposal_id, :big_int, null: true, index: true
      column :disposed_on, :date
      column :kind, :string, max_size: 8, default: "sale"
      column :price, :decimal, max_digits: 20, decimal_places: 2, default: 0
      column :label, :string, max_size: 255, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :amortis_impairment do
      column :id, :big_int, primary_key: true, auto: true
      column :asset_id, :big_int, index: true
      column :date, :date
      column :amount, :decimal, max_digits: 20, decimal_places: 2
      column :label, :string, max_size: 255, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :amortis_posting do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 16
      column :exercise_start, :date
      column :exercise_end, :date
      column :fiscal_year_id, :big_int, null: true
      column :asset_id, :big_int, null: true, index: true
      column :impairment_id, :big_int, null: true
      column :disposal_id, :big_int, null: true
      column :ledger_id, :big_int
      column :entry_id, :big_int, unique: true
      column :date, :date
      column :amount, :decimal, max_digits: 20, decimal_places: 2, default: 0
      column :status, :string, max_size: 16, default: "posted"
      column :reversal_entry_id, :big_int, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :amortis_posting_line do
      column :id, :big_int, primary_key: true, auto: true
      column :posting_id, :big_int, index: true
      column :asset_id, :big_int, index: true
      column :exercise_start, :date
      column :depreciation, :decimal, max_digits: 20, decimal_places: 2, default: 0
      column :derogatory, :decimal, max_digits: 20, decimal_places: 2, default: 0
      column :impairment, :decimal, max_digits: 20, decimal_places: 2, default: 0
    end

    create_table :amortis_setting do
      column :id, :big_int, primary_key: true, auto: true
      column :ledger_id, :big_int, null: true
      column :day_count, :string, max_size: 8, default: "actual"
      column :expense_account, :string, max_size: 40, default: ""
      column :impairment_expense_account, :string, max_size: 40, default: ""
      column :impairment_income_account, :string, max_size: 40, default: ""
      column :derogatory_account, :string, max_size: 40, default: ""
      column :derogatory_expense_account, :string, max_size: 40, default: ""
      column :derogatory_income_account, :string, max_size: 40, default: ""
      column :disposal_expense_account, :string, max_size: 40, default: ""
      column :disposal_income_account, :string, max_size: 40, default: ""
      column :disposal_receivable_account, :string, max_size: 40, default: ""
      column :be_individual, :bool, default: false
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
