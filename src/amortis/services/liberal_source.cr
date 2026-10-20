# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Immobilisations de la 2035 fournies au module `liberal` (A-AMO-3,
  # D-AMO-018) : le registre de l'exercice (`Statements.register`, plan
  # fiscal, D-AMO-014) devient le tableau des immobilisations et des
  # amortissements de la 2035 (`DepreciationRowView`) et ses cessions
  # (`DisposalResultView`), à la place du registre linéaire du module.
  # Enregistré auprès de `Partiduo::Api::Liberal.register_asset_source` au
  # chargement de l'extension (`app.cr`) : le module `liberal` ne l'appelle
  # que si `AMORTIS` est actif. Interne ; contrat : `Api.liberal_assets`.
  module LiberalSource
    alias Liberal = Partiduo::Api::Liberal
    alias D = BigDecimal

    # Catégorie du registre de `liberal` (`Liberal::ASSET_CATEGORIES`)
    # d'une rubrique de l'extension ; le compte départage le fonds
    # commercial (207) et le mobilier (2184).
    CATEGORIES = {
      "establishment" => "intangible", "intangible" => "intangible", "land" => "land", "building_own" => "building",
      "building_other" => "building", "building_fittings" => "fittings", "general_fittings" => "fittings",
      "technical" => "equipment", "transport" => "vehicle", "office" => "office",
    }

    def self.category(regime : String, account : String) : String
      return "goodwill" if account.starts_with?("207")
      return "furniture" if account.starts_with?("2184")
      CATEGORIES[Rubrics.for(regime, account).code]? || "other"
    end

    # Exercice du socle de l'année civile `year` de la 2035 : celui qui se
    # clôt cette année-là (le premier s'il y en a deux).
    def self.exercise(year : Int32) : Exercise?
      Records.known_exercises.sort_by(&.starts_on).find(&.ends_on.year.==(year))
    end

    # Vue de la 2035 ; `nil` hors de France, sans exercice pour l'année ou
    # sans immobilisation (la 2035 garde alors le registre du module).
    def self.view(year : Int32) : Liberal::AssetSourceView?
      context = Schedules::Context.new
      return unless context.regime == "fr"
      exercise = exercise(year) || return
      register = Statements.register(context, exercise)
      return if register.rows.empty?
      assets = Asset.filter(id__in: register.rows.map(&.asset_id)).to_a.index_by(&.id!.to_i64)
      rows = register.rows.map do |row|
        asset = assets[row.asset_id]
        months = asset.fiscal_life_months || asset.life_months || 0
        Liberal::DepreciationRowView.new(row.asset_id, row.code, row.label,
          category(context.regime, asset.asset_account.to_s), row.acquired_on, row.in_service_on || row.acquired_on,
          row.base, (months / 12).round.to_i, row.rate, row.prior, row.charge, row.disposed_on)
      end
      disposals = register.rows.compact_map do |row|
        date = row.disposed_on || next
        Liberal::DisposalResultView.new(row.asset_id, row.code, row.label, date, row.price || D.new(0), row.net_value,
          row.cumul, row.short_term || D.new(0), row.long_term || D.new(0))
      end
      Liberal::AssetSourceView.new(rows, disposals, "amortis.module.name")
    end
  end
end
