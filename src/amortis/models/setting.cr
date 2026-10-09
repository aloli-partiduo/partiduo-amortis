# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Réglages du dossier (une ligne au plus ; à défaut, ceux du régime,
  # D-AMO-011) : journal d'opérations diverses des écritures d'inventaire,
  # convention de décompte des jours du prorata, comptes par défaut,
  # contribuable belge personne physique (dégressif encore admis).
  # Interne.
  class Setting < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :ledger_id, :big_int, blank: true, null: true
    field :day_count, :string, max_size: 8, default: "actual"
    field :expense_account, :string, max_size: 40, blank: true, default: ""
    field :impairment_expense_account, :string, max_size: 40, blank: true, default: ""
    field :impairment_income_account, :string, max_size: 40, blank: true, default: ""
    field :derogatory_account, :string, max_size: 40, blank: true, default: ""
    field :derogatory_expense_account, :string, max_size: 40, blank: true, default: ""
    field :derogatory_income_account, :string, max_size: 40, blank: true, default: ""
    field :disposal_expense_account, :string, max_size: 40, blank: true, default: ""
    field :disposal_income_account, :string, max_size: 40, blank: true, default: ""
    field :disposal_receivable_account, :string, max_size: 40, blank: true, default: ""
    field :be_individual, :bool, default: false

    with_timestamp_fields
  end
end
