# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Sortie d'une immobilisation (D-AMO-008) : cession (`sale`, prix de
  # cession) ou mise au rebut (`scrap`, prix nul). La sortie d'une
  # immobilisation entraîne celle de ses composants encore présents
  # (`parent_disposal_id`, prix nul). Une immobilisation n'a qu'une sortie.
  # Interne.
  class Disposal < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :asset_id, :big_int, unique: true
    field :parent_disposal_id, :big_int, blank: true, null: true
    field :disposed_on, :date
    field :kind, :string, max_size: 8, default: "sale"
    field :price, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
    field :label, :string, max_size: 255, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
