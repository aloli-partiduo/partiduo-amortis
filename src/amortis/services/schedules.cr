# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Plans des immobilisations enregistrées (D-AMO-005) : entrée du calcul
  # tirée de la ligne, exercices du socle prolongés, lignes du plan, vues du
  # registre. Un `Context` garde le régime, les réglages et les exercices le
  # temps d'une requête. Interne.
  module Schedules
    alias Api = Amortis::Api
    alias D = BigDecimal

    ZERO = BigDecimal.new(0)

    class Context
      getter regime : String
      getter settings : Api::SettingsView
      getter known : Array(Exercise)
      getter closed : Set(Int64)
      @impairments : Hash(Int64, Array(Impairment))? = nil
      @disposals : Hash(Int64, Disposal)? = nil

      def initialize
        @settings = Settings.view
        @regime = @settings.regime
        @known = Records.known_exercises
        @closed = Records.closed_years
      end

      def impairments(asset_id : Int64) : Array(Impairment)
        (@impairments ||= Impairment.all.order(:date, :id).to_a.group_by(&.asset_id!.to_i64))[asset_id]? || [] of Impairment
      end

      def disposal(asset_id : Int64) : Disposal?
        (@disposals ||= Disposal.all.to_a.to_h { |row| {row.asset_id!.to_i64, row} })[asset_id]?
      end

      def exercises(from : Time, to : Time) : Array(Exercise)
        Calendar.exercises(known, from, to)
      end

      def exercise_on(day : Time) : Exercise
        Calendar.find(exercises(day, day), day) || raise "exercice introuvable"
      end
    end

    def self.input(context : Context, row : Asset, disposed_on : Time? = nil) : Plan::Input
      disposal = context.disposal(row.id!.to_i64)
      Plan::Input.new(regime: context.regime, day_count: context.settings.day_count, acquired_on: row.acquired_on!,
        in_service_on: row.in_service_on, gross: row.gross_value!, residual: row.residual_value || ZERO,
        method: row.method.to_s, life_months: (row.life_months || 0).to_i32, fiscal_method: row.fiscal_method.to_s,
        fiscal_life_months: row.fiscal_life_months.try(&.to_i32),
        impairments: context.impairments(row.id!.to_i64).map { |item| {item.date!, item.amount!} },
        disposed_on: disposed_on || disposal.try(&.disposed_on))
    end

    def self.rows(context : Context, row : Asset, disposed_on : Time? = nil) : Array(Plan::Row)
      plan = input(context, row, disposed_on)
      from, to = Plan.horizon(plan)
      Plan.rows(plan, context.exercises(from, to))
    end

    # Ligne du plan à la clôture de l'exercice qui contient `day` (ou la
    # dernière avant lui) ; `nil` avant le premier exercice du plan.
    def self.row_at(rows : Array(Plan::Row), day : Time) : Plan::Row?
      rows.reverse_each.find { |row| row.exercise.starts_on <= day }
    end

    # Coefficient et taux du plan : comptable, ou fiscal s'il est dégressif ;
    # `fiscal` : celui du plan fiscal dès qu'il est distinct (registre de la
    # 2035).
    def self.rate(context : Context, row : Asset, fiscal : Bool = false) : {D?, D?}
      distinct = context.regime == "fr" && row.fiscal_method.to_s != "same"
      method, months = if distinct && (fiscal || row.fiscal_method.to_s == "degressive")
                         {row.fiscal_method.to_s, (row.fiscal_life_months || 0).to_i32}
                       else
                         {row.method.to_s, (row.life_months || 0).to_i32}
                       end
      return {nil, nil} if method == "none" || months <= 0
      linear = BigDecimal.new(1200) / months
      if method == "degressive"
        if context.regime == "be"
          {nil, (Coefficients.be_rate(months) * 100).round(2)}
        elsif coefficient = Coefficients.fr(row.acquired_on!, months)
          {coefficient, (linear * coefficient).round(2)}
        else
          {nil, linear.round(2)}
        end
      else
        {nil, linear.round(2)}
      end
    end

    def self.status(row : Asset, plan : Array(Plan::Row), disposal : Disposal?, as_of : Time) : String
      return "disposed" if disposal
      return "pending" if row.in_service_on.nil?
      last = row_at(plan, as_of)
      last && row.method.to_s != "none" && last.net_value <= (row.residual_value || ZERO) && plan.last == last ? "depreciated" : "in_service"
    end

    def self.asset_view(context : Context, row : Asset, plan : Array(Plan::Row)? = nil,
                        as_of : Time = Records.today) : Api::AssetView
      id = row.id!.to_i64
      plan ||= rows(context, row)
      disposal = context.disposal(id)
      at = row_at(plan, as_of)
      coefficient, rate = rate(context, row)
      parent_code = row.parent_id.try { |parent| Asset.filter(id: parent).first.try(&.code.to_s) }
      disposal_view = disposal.try do |item|
        Records.disposal_view(item, Plan.disposal(input(context, row), plan, item.price || ZERO))
      end
      expense = row.expense_account.to_s
      Api::AssetView.new(id: id, parent_id: row.parent_id.try(&.to_i64), parent_code: parent_code, code: row.code.to_s,
        label: row.label.to_s, card_code: row.card_code.to_s, asset_account: row.asset_account.to_s,
        depreciation_account: row.depreciation_account.to_s, impairment_account: row.impairment_account.to_s,
        expense_account: expense.empty? ? context.settings.account("expense_account") : expense,
        expense_account_default: expense.empty?, rubric: Rubrics.for(context.regime, row.asset_account.to_s).code,
        acquired_on: row.acquired_on!, in_service_on: row.in_service_on, gross_value: row.gross_value!,
        residual_value: row.residual_value || ZERO, method: row.method.to_s, life_months: (row.life_months || 0).to_i32,
        fiscal_method: row.fiscal_method.to_s, fiscal_life_months: row.fiscal_life_months.try(&.to_i32),
        new_asset: row.new_asset == true, coefficient: coefficient, rate: rate, entry_id: row.entry_id.try(&.to_i64),
        entry_line_id: row.entry_line_id.try(&.to_i64), notes: row.notes.to_s,
        component_count: Asset.filter(parent_id: id).count.to_i32, status: status(row, plan, disposal, as_of),
        locked: Records.locked?(id), as_of: at.try(&.exercise.ends_on) || as_of,
        accounting_cumul: at.try(&.accounting_cumul) || ZERO, impairment_cumul: at.try(&.impairment_cumul) || ZERO,
        derogatory_cumul: at.try(&.derogatory_cumul) || ZERO,
        net_value: at.try(&.net_value) || row.gross_value!, disposal: disposal_view, created_at: row.created_at || Time.utc)
    end

    def self.schedule_view(context : Context, row : Asset) : Api::ScheduleView
      plan = rows(context, row)
      posted = Records.posted_amounts([row.id!.to_i64])
      view = asset_view(context, row, plan)
      rows = plan.map do |item|
        depreciation, derogatory = posted[{row.id!.to_i64, Records.iso(item.exercise.starts_on)}]? || {ZERO, ZERO}
        Api::ScheduleRowView.new(exercise: Records.exercise_view(item.exercise, context.closed),
          accounting_opening: item.accounting_opening, accounting: item.accounting, accounting_cumul: item.accounting_cumul,
          accounting_mode: item.accounting_mode, impairment: item.impairment, impairment_cumul: item.impairment_cumul,
          net_value: item.net_value, fiscal: item.fiscal, fiscal_cumul: item.fiscal_cumul, fiscal_mode: item.fiscal_mode,
          derogatory: item.derogatory, derogatory_cumul: item.derogatory_cumul, posted_depreciation: depreciation,
          posted_derogatory: derogatory, disposed: item.disposed)
      end
      Api::ScheduleView.new(asset: view, rows: rows, derogatory: input(context, row).derogatory?, disposal: view.disposal)
    end
  end
end
