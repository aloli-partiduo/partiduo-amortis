# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Immobilisation inscrite au registre (D-AMO-003), ou composant d'une
  # immobilisation (`parent_id`, approche par composants du PCG, D-AMO-007).
  #
  # * comptes : immobilisation (`2…`), amortissements (`28…` en France,
  #   `2x9` en Belgique), dépréciations (`29…`), dotation (`expense_account`,
  #   vide : celui des réglages) ;
  # * dates : acquisition (départ du dégressif français), mise en service
  #   (départ du linéaire ; vide : pas encore amortie) ;
  # * plan comptable : valeur brute, valeur résiduelle, mode, durée d'usage
  #   en mois ; plan fiscal : mode (`same` : celui du plan comptable),
  #   durée fiscale en mois — l'écart fait l'amortissement dérogatoire ;
  # * `entry_line_id` : ligne de l'écriture d'acquisition, relue par le
  #   contrat de la Comptabilité, sans clé étrangère (D-AMO-004).
  #
  # Interne.
  class Asset < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :parent_id, :big_int, blank: true, null: true
    field :code, :string, max_size: 30
    field :label, :string, max_size: 255
    field :card_code, :string, max_size: 64, blank: true, default: ""
    field :asset_account, :string, max_size: 40
    field :depreciation_account, :string, max_size: 40, blank: true, default: ""
    field :impairment_account, :string, max_size: 40, blank: true, default: ""
    field :expense_account, :string, max_size: 40, blank: true, default: ""
    field :acquired_on, :date
    field :in_service_on, :date, blank: true, null: true
    field :gross_value, :decimal, max_digits: 20, decimal_places: 2
    field :residual_value, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
    field :method, :string, max_size: 16, default: "linear"
    field :life_months, :int, default: 0
    field :fiscal_method, :string, max_size: 16, default: "same"
    field :fiscal_life_months, :int, blank: true, null: true
    field :new_asset, :bool, default: true
    field :entry_id, :big_int, blank: true, null: true
    field :entry_line_id, :big_int, blank: true, null: true
    field :notes, :text, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
