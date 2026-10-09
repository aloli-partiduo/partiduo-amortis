# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # États d'un exercice (D-AMO-013, D-AMO-014), calculés depuis les plans
  # (les dotations non encore passées sont signalées) :
  #
  # * tableau des immobilisations et des amortissements par rubrique —
  #   annexes 2054 (valeurs brutes) et 2055 (amortissements ventilés par
  #   mode, mouvements des amortissements dérogatoires) de la liasse en
  #   France ; état des immobilisations de l'annexe des comptes annuels en
  #   Belgique ;
  # * registre des immobilisations et des amortissements (plan fiscal) de
  #   la 2035, avec les plus ou moins-values à court et à long terme.
  #
  # Interne.
  module Statements
    alias Api = Amortis::Api
    alias D = BigDecimal

    ZERO = BigDecimal.new(0)

    FIELDS = %w[gross_opening gross_increase gross_decrease depreciation_opening depreciation_charge depreciation_decrease
      charge_linear charge_degressive impairment_opening impairment_charge impairment_release derogatory_opening
      derogatory_charge_duration derogatory_charge_degressive derogatory_release_duration derogatory_release_degressive]

    def self.statement(context : Schedules::Context, exercise : Exercise) : Api::StatementView
      sums = {} of String => Hash(String, D)
      Asset.all.order(:code, :id).to_a.each do |row|
        disposal = context.disposal(row.id!.to_i64)
        next if row.acquired_on! > exercise.ends_on
        next if disposal && disposal.disposed_on! < exercise.starts_on
        rubric = Rubrics.for(context.regime, row.asset_account.to_s).code
        values = sums[rubric] ||= Hash(String, D).new(ZERO)
        add(values, context, row, disposal, exercise)
      end
      rows = Rubrics.list(context.regime).compact_map { |rubric| sums[rubric.code]?.try { |values| row_view(rubric, values) } }
      total = Hash(String, D).new(ZERO)
      sums.each_value { |values| FIELDS.each { |field| total[field] += values[field] } }
      Api::StatementView.new(exercise: Records.exercise_view(exercise, context.closed), regime: context.regime, rows: rows,
        total: row_view(Rubrics::Rubric.new("total", "total", [] of String), total),
        unposted: Postings.proposal(context, exercise).total_depreciation)
    end

    private def self.add(values : Hash(String, D), context : Schedules::Context, row : Asset, disposal : Disposal?,
                         exercise : Exercise) : Nil
      gross = row.gross_value!
      disposed = !disposal.nil? && exercise.includes?(disposal.disposed_on!)
      values["gross_opening"] += gross if row.acquired_on! < exercise.starts_on
      values["gross_increase"] += gross if exercise.includes?(row.acquired_on!)
      values["gross_decrease"] += gross if disposed
      plan = Schedules.rows(context, row)
      before = plan.reverse_each.find(&.exercise.ends_on.<(exercise.starts_on))
      values["depreciation_opening"] += before.try(&.accounting_cumul) || ZERO
      values["impairment_opening"] += before.try(&.impairment_cumul) || ZERO
      values["derogatory_opening"] += before.try(&.derogatory_cumul) || ZERO
      current = plan.find(&.exercise.starts_on.==(exercise.starts_on)) || return
      movements(values, current, row.fiscal_method.to_s == "degressive", disposed)
    end

    # Mouvements de l'exercice : dotations par mode, dépréciations,
    # dérogatoires (différentiel de durée ou mode dégressif) ; à la sortie,
    # les cumuls sortent.
    private def self.movements(values : Hash(String, D), current : Plan::Row, degressive : Bool, disposed : Bool) : Nil
      values["depreciation_charge"] += current.accounting
      values[current.accounting_mode == "degressive" ? "charge_degressive" : "charge_linear"] += current.accounting
      if current.impairment > 0
        values["impairment_charge"] += current.impairment
      else
        values["impairment_release"] -= current.impairment
      end
      charge, release = degressive ? {"derogatory_charge_degressive", "derogatory_release_degressive"} : {"derogatory_charge_duration", "derogatory_release_duration"}
      current.derogatory > 0 ? (values[charge] += current.derogatory) : (values[release] -= current.derogatory)
      return unless disposed
      values["depreciation_decrease"] += current.accounting_cumul
      values["impairment_release"] += current.impairment_cumul
      values[release] += current.derogatory_cumul
    end

    private def self.row_view(rubric : Rubrics::Rubric, values : Hash(String, D)) : Api::StatementRowView
      gross = values["gross_opening"] + values["gross_increase"] - values["gross_decrease"]
      depreciation = values["depreciation_opening"] + values["depreciation_charge"] - values["depreciation_decrease"]
      impairment = values["impairment_opening"] + values["impairment_charge"] - values["impairment_release"]
      derogatory = values["derogatory_opening"] + values["derogatory_charge_duration"] + values["derogatory_charge_degressive"] -
                   values["derogatory_release_duration"] - values["derogatory_release_degressive"]
      Api::StatementRowView.new(rubric: rubric.code, group: rubric.group, gross_opening: values["gross_opening"],
        gross_increase: values["gross_increase"], gross_decrease: values["gross_decrease"], gross_closing: gross,
        depreciation_opening: values["depreciation_opening"], depreciation_charge: values["depreciation_charge"],
        depreciation_decrease: values["depreciation_decrease"], depreciation_closing: depreciation,
        charge_linear: values["charge_linear"], charge_degressive: values["charge_degressive"],
        impairment_opening: values["impairment_opening"], impairment_charge: values["impairment_charge"],
        impairment_release: values["impairment_release"], impairment_closing: impairment,
        derogatory_opening: values["derogatory_opening"], derogatory_charge_duration: values["derogatory_charge_duration"],
        derogatory_charge_degressive: values["derogatory_charge_degressive"],
        derogatory_release_duration: values["derogatory_release_duration"],
        derogatory_release_degressive: values["derogatory_release_degressive"], derogatory_closing: derogatory,
        net_closing: gross - depreciation - impairment)
    end

    def self.register(context : Schedules::Context, exercise : Exercise) : Api::RegisterView
      rows = [] of Api::RegisterRowView
      Asset.all.order(:acquired_on, :code, :id).to_a.each do |row|
        disposal = context.disposal(row.id!.to_i64)
        next if row.acquired_on! > exercise.ends_on
        next if disposal && disposal.disposed_on! < exercise.starts_on
        plan = Schedules.rows(context, row)
        before = plan.reverse_each.find(&.exercise.ends_on.<(exercise.starts_on))
        current = plan.find(&.exercise.starts_on.==(exercise.starts_on))
        prior = before.try(&.fiscal_cumul) || ZERO
        charge = current.try(&.fiscal) || ZERO
        _, rate = Schedules.rate(context, row, fiscal: true)
        method = row.fiscal_method.to_s == "same" ? row.method.to_s : row.fiscal_method.to_s
        disposed = disposal if disposal && exercise.includes?(disposal.disposed_on!)
        result = disposed.try { |item| Plan.disposal(Schedules.input(context, row), plan, item.price || ZERO) }
        rows << Api::RegisterRowView.new(asset_id: row.id!.to_i64, code: row.code.to_s, label: row.label.to_s,
          acquired_on: row.acquired_on!, in_service_on: row.in_service_on, base: row.gross_value!, method: method,
          rate: rate, prior: prior, charge: charge, cumul: prior + charge, net_value: row.gross_value! - prior - charge,
          disposed_on: disposed.try(&.disposed_on), price: disposed.try(&.price),
          short_term: result.try(&.short_term), long_term: result.try(&.long_term))
      end
      Api::RegisterView.new(exercise: Records.exercise_view(exercise, context.closed), rows: rows,
        total_base: rows.sum(ZERO, &.base), total_prior: rows.sum(ZERO, &.prior), total_charge: rows.sum(ZERO, &.charge),
        total_net: rows.sum(ZERO, &.net_value), total_short_term: rows.sum(ZERO) { |item| item.short_term || ZERO },
        total_long_term: rows.sum(ZERO) { |item| item.long_term || ZERO })
    end
  end
end
