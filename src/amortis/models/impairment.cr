# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Dépréciation d'une immobilisation (D-AMO-010) : montant positif pour une
  # dotation, négatif pour une reprise, à une date. Le plan comptable
  # repart, dès l'exercice suivant, de la valeur nette après dépréciation
  # sur la durée restante. Interne.
  class Impairment < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :asset_id, :big_int
    field :date, :date
    field :amount, :decimal, max_digits: 20, decimal_places: 2
    field :label, :string, max_size: 255, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
