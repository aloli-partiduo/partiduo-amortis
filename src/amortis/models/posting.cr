# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Écriture d'inventaire passée par l'extension (D-AMO-009) : dotations
  # d'un exercice (`depreciation`), dépréciation (`impairment`) ou sortie
  # d'actif (`disposal`). L'écriture est celle de la Comptabilité
  # (`entry_id`, sans clé étrangère) ; `cancelled` quand elle est
  # extournée, ici ou dans la Comptabilité (`entry.cancelled`). Interne.
  class Posting < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :kind, :string, max_size: 16
    field :exercise_start, :date
    field :exercise_end, :date
    field :fiscal_year_id, :big_int, blank: true, null: true
    field :asset_id, :big_int, blank: true, null: true
    field :impairment_id, :big_int, blank: true, null: true
    field :disposal_id, :big_int, blank: true, null: true
    field :ledger_id, :big_int
    field :entry_id, :big_int, unique: true
    field :date, :date
    field :amount, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
    field :status, :string, max_size: 16, default: "posted"
    field :reversal_entry_id, :big_int, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Montants d'une écriture d'inventaire, par immobilisation et par
  # exercice : amortissement comptable, dérogatoire (positif : dotation,
  # négatif : reprise), dépréciation. Ils disent ce qui est déjà passé,
  # pour ne proposer que le reste. Interne.
  class PostingLine < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :posting_id, :big_int
    field :asset_id, :big_int
    field :exercise_start, :date
    field :depreciation, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
    field :derogatory, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
    field :impairment, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
  end
end
