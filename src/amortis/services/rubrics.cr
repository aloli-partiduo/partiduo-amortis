# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Rubriques des états des immobilisations (D-AMO-013), par préfixe du
  # compte d'immobilisation (le plus long l'emporte) : lignes du tableau
  # 2054 du PCG en France, classes du PCMN en Belgique. Libellé :
  # `amortis.rubrics.<code>` ; groupe : `amortis.rubric_groups.<code>`.
  # Interne.
  module Rubrics
    record Rubric, code : String, group : String, prefixes : Array(String)

    FR = [
      Rubric.new("establishment", "intangible", %w[201 203]),
      Rubric.new("intangible", "intangible", %w[20 232 237]),
      Rubric.new("land", "tangible", %w[211 212]),
      Rubric.new("building_own", "tangible", %w[213]),
      Rubric.new("building_other", "tangible", %w[214]),
      Rubric.new("building_fittings", "tangible", %w[2135 2145]),
      Rubric.new("technical", "tangible", %w[215]),
      Rubric.new("general_fittings", "tangible", %w[2181]),
      Rubric.new("transport", "tangible", %w[2182]),
      Rubric.new("office", "tangible", %w[2183 2184]),
      Rubric.new("other_tangible", "tangible", %w[21 22]),
      Rubric.new("in_progress", "tangible", %w[231]),
      Rubric.new("advances", "tangible", %w[238]),
      Rubric.new("participations", "financial", %w[26]),
      Rubric.new("securities", "financial", %w[271 272 273]),
      Rubric.new("loans", "financial", %w[27]),
    ]

    BE = [
      Rubric.new("be_establishment", "intangible", %w[20]),
      Rubric.new("be_intangible", "intangible", %w[21]),
      Rubric.new("be_land_buildings", "tangible", %w[22]),
      Rubric.new("be_plant", "tangible", %w[23]),
      Rubric.new("be_furniture_vehicles", "tangible", %w[24]),
      Rubric.new("be_leasing", "tangible", %w[25]),
      Rubric.new("be_other_tangible", "tangible", %w[26]),
      Rubric.new("be_in_progress", "tangible", %w[27]),
      Rubric.new("be_financial", "financial", %w[28]),
    ]

    OTHER = Rubric.new("other", "other", [] of String)

    def self.list(regime : String) : Array(Rubric)
      (regime == "be" ? BE : FR) + [OTHER]
    end

    def self.for(regime : String, account : String) : Rubric
      best = nil
      length = 0
      list(regime).each do |rubric|
        rubric.prefixes.each do |prefix|
          if account.starts_with?(prefix) && prefix.size > length
            best = rubric
            length = prefix.size
          end
        end
      end
      best || OTHER
    end

    def self.all_codes : Array(String)
      (FR + BE + [OTHER]).map(&.code)
    end

    def self.groups : Array(String)
      %w[intangible tangible financial other]
    end
  end
end
