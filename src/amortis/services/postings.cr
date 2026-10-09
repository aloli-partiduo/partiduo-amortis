# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Écritures d'inventaire (D-AMO-009) : dotations d'un exercice,
  # dépréciation, sortie d'actif. Elles sont *proposées* (ce que le plan
  # prévoit moins ce qui est déjà passé), puis passées à la demande par
  # `Partiduo::Api::Accounting.post_entry`, le seul service d'écriture du
  # cœur (ADR-003 D6), dans un journal d'opérations diverses ; jamais de
  # table comptable propre. Interne.
  module Postings
    alias Acc = Partiduo::Api::Accounting
    alias Api = Amortis::Api
    alias Side = Partiduo::Api::Accounting::Side
    alias FieldError = Partiduo::Api::FieldError
    alias D = BigDecimal

    ZERO = BigDecimal.new(0)

    # Référence de l'écriture (`source`) : ce qui l'a produite.
    SOURCE = "amortis:"

    # Lignes d'une écriture en préparation, regroupées par compte et par
    # sens (premier libellé gardé).
    class Builder
      getter order = [] of {String, Side}
      getter amounts = {} of {String, Side} => D
      getter labels = {} of {String, Side} => String

      def line(account : String, side : Side, amount : D, label : String) : Nil
        return if amount.zero?
        if amount < 0
          side = side.opposite
          amount = -amount
        end
        key = {account, side}
        order << key unless amounts.has_key?(key)
        amounts[key] = (amounts[key]? || ZERO) + amount
        labels[key] ||= label
      end

      # Débit de `debit`, crédit de `credit` ; un montant négatif inverse les
      # deux.
      def pair(debit : String, credit : String, amount : D, label : String) : Nil
        line(debit, Side::Debit, amount, label)
        line(credit, Side::Credit, amount, label)
      end

      def views : Array(Api::EntryLineView)
        order.map { |key| Api::EntryLineView.new(key[0], key[1], amounts[key], labels[key]) }
      end

      def total_debit : D
        amounts.select { |key, _| key[1].debit? }.values.sum(ZERO)
      end

      def accounts : Array(String)
        order.map(&.[0]).uniq!
      end
    end

    # --- Dotations d'un exercice ------------------------------------------------------

    record Delta, row : Asset, depreciation : D, derogatory : D, mode : String

    def self.proposal(context : Schedules::Context, exercise : Exercise, asset_ids : Array(Int64)? = nil,
                      ledger_id : Int64? = nil) : Api::ProposalView
      deltas, disposals, impairments = deltas(context, exercise, asset_ids)
      builder = build_depreciation(context, exercise, deltas)
      lines = deltas.map do |delta|
        row = delta.row
        Api::ProposalLineView.new(asset_id: row.id!.to_i64, code: row.code.to_s, label: row.label.to_s,
          depreciation: delta.depreciation, derogatory: delta.derogatory, accounting_mode: delta.mode,
          expense_account: expense_account(context, row), depreciation_account: row.depreciation_account.to_s)
      end
      ledger = ledger_id || default_ledger_id(context)
      blockers = account_blockers(builder)
      blockers << Records.error("ledger_id", "ledger.blank") if ledger.nil? && !lines.empty?
      Api::ProposalView.new(exercise: Records.exercise_view(exercise, context.closed), lines: lines,
        entry_lines: builder.views, total_depreciation: deltas.sum(ZERO, &.depreciation),
        total_derogatory: deltas.sum(ZERO, &.derogatory), ledger_id: ledger, date: exercise.ends_on, blockers: blockers,
        disposals: disposals.map { |row| Schedules.asset_view(context, row) },
        impairments: impairments.map { |row| Records.impairment_view(row) })
    end

    private def self.deltas(context : Schedules::Context, exercise : Exercise,
                            asset_ids : Array(Int64)?) : {Array(Delta), Array(Asset), Array(Impairment)}
      rows = Asset.all.order(:code, :id).to_a
      rows = rows.select { |row| asset_ids.includes?(row.id!.to_i64) } if asset_ids
      posted = Records.posted_amounts(rows.map(&.id!.to_i64))
      key = Records.iso(exercise.starts_on)
      deltas = [] of Delta
      impairments = [] of Impairment
      rows.each do |row|
        id = row.id!.to_i64
        context.impairments(id).each do |item|
          impairments << item if exercise.includes?(item.date!) && Records.live_posting(impairment_id: item.id!.to_i64).nil?
        end
        if disposal = context.disposal(id)
          next unless disposal.disposed_on! > exercise.ends_on
        end
        item = Schedules.rows(context, row).find(&.exercise.starts_on.==(exercise.starts_on)) || next
        depreciation, derogatory = posted[{id, key}]? || {ZERO, ZERO}
        delta = Delta.new(row, item.accounting - depreciation, item.derogatory - derogatory, item.accounting_mode)
        deltas << delta unless delta.depreciation.zero? && delta.derogatory.zero?
      end
      {deltas, pending_disposals(context, rows, exercise), impairments}
    end

    # Sorties de l'exercice dont l'écriture reste à passer (la dotation de
    # l'exercice y figure) ; les composants sortis avec leur structure
    # passent par elle.
    private def self.pending_disposals(context : Schedules::Context, rows : Array(Asset), exercise : Exercise) : Array(Asset)
      rows.select do |row|
        disposal = context.disposal(row.id!.to_i64)
        !disposal.nil? && exercise.includes?(disposal.disposed_on!) && disposal.parent_disposal_id.nil? &&
          Records.live_posting(disposal_id: disposal.id!.to_i64).nil?
      end
    end

    private def self.build_depreciation(context : Schedules::Context, exercise : Exercise, deltas : Array(Delta)) : Builder
      builder = Builder.new
      label = I18n.t("amortis.entries.depreciation", exercise: exercise.display_label)
      deltas.each do |delta|
        builder.pair(expense_account(context, delta.row), delta.row.depreciation_account.to_s, delta.depreciation, label)
      end
      deltas.each { |delta| derogatory(context, builder, delta.derogatory, exercise) }
      builder
    end

    # Dérogatoire de l'exercice : dotation (6872 / 145) ou reprise
    # (145 / 7872).
    private def self.derogatory(context : Schedules::Context, builder : Builder, amount : D, exercise : Exercise) : Nil
      settings = context.settings
      if amount > 0
        builder.pair(settings.account("derogatory_expense_account"), settings.account("derogatory_account"), amount,
          I18n.t("amortis.entries.derogatory_charge", exercise: exercise.display_label))
      elsif amount < 0
        builder.pair(settings.account("derogatory_account"), settings.account("derogatory_income_account"), -amount,
          I18n.t("amortis.entries.derogatory_release", exercise: exercise.display_label))
      end
    end

    def self.post_depreciation(actor : Partiduo::Api::Actor, context : Schedules::Context, exercise : Exercise,
                               input : Api::PostInput) : Partiduo::Api::Result(Api::PostingView)
      failure = ->(errors : Array(FieldError)) { Partiduo::Api::Result(Api::PostingView).failure(errors) }
      deltas, _, _ = deltas(context, exercise, input.asset_ids)
      return failure.call([Records.error(FieldError::BASE, "posting.nothing")]) if deltas.empty?
      builder = build_depreciation(context, exercise, deltas)
      date = input.date || exercise.ends_on
      errors = account_blockers(builder)
      errors << Records.error("date", "posting.date.outside", {"from" => Records.iso(exercise.starts_on), "to" => Records.iso(exercise.ends_on)}) unless exercise.includes?(date)
      ledger_id = resolve_ledger(context, input.ledger_id, errors)
      return failure.call(errors) unless errors.empty? && ledger_id
      label = I18n.t("amortis.entries.depreciation", exercise: exercise.display_label)
      post(actor, builder, ledger_id, date, label, "#{SOURCE}depreciation:#{Records.iso(exercise.starts_on)}", "depreciation",
        exercise, nil, nil, nil) do |posting|
        deltas.each do |delta|
          PostingLine.create!(posting_id: posting.id, asset_id: delta.row.id, exercise_start: exercise.starts_on,
            depreciation: delta.depreciation, derogatory: delta.derogatory, impairment: ZERO)
        end
      end
    end

    # --- Dépréciation -------------------------------------------------------------------

    def self.impairment_builder(context : Schedules::Context, asset : Asset, row : Impairment) : Builder
      builder = Builder.new
      settings = context.settings
      amount = row.amount!
      label = row.label.to_s.presence || I18n.t("amortis.entries.impairment", code: asset.code.to_s)
      if amount > 0
        builder.pair(settings.account("impairment_expense_account"), asset.impairment_account.to_s, amount, label)
      else
        builder.pair(asset.impairment_account.to_s, settings.account("impairment_income_account"), -amount, label)
      end
      builder
    end

    def self.post_impairment(actor : Partiduo::Api::Actor, context : Schedules::Context, row : Impairment,
                             input : Api::PostInput) : Partiduo::Api::Result(Api::PostingView)
      failure = ->(errors : Array(FieldError)) { Partiduo::Api::Result(Api::PostingView).failure(errors) }
      if Records.live_posting(impairment_id: row.id!.to_i64)
        return failure.call([Records.error(FieldError::BASE, "impairment.posted")])
      end
      asset = Records.asset!(row.asset_id!.to_i64)
      builder = impairment_builder(context, asset, row)
      errors = account_blockers(builder)
      ledger_id = resolve_ledger(context, input.ledger_id, errors)
      return failure.call(errors) unless errors.empty? && ledger_id
      exercise = context.exercise_on(row.date!)
      label = I18n.t("amortis.entries.impairment", code: asset.code.to_s)
      post(actor, builder, ledger_id, row.date!, label, "#{SOURCE}impairment:#{row.id}", "impairment", exercise, asset,
        row, nil) do |posting|
        PostingLine.create!(posting_id: posting.id, asset_id: asset.id, exercise_start: exercise.starts_on,
          depreciation: ZERO, derogatory: ZERO, impairment: row.amount!)
      end
    end

    # --- Sortie d'actif -----------------------------------------------------------------

    record Member, row : Asset, disposal : Disposal, depreciation : D, derogatory : D, result : Plan::DisposalResult

    def self.disposal_members(context : Schedules::Context, asset : Asset, disposal : Disposal) : Array(Member)
      exercise = context.exercise_on(disposal.disposed_on!)
      key = Records.iso(exercise.starts_on)
      group = [{asset, disposal}] + Disposal.filter(parent_disposal_id: disposal.id).to_a.map do |item|
        {Records.asset!(item.asset_id!.to_i64), item}
      end
      posted = Records.posted_amounts(group.map(&.[0].id!.to_i64))
      group.map do |(row, item)|
        plan = Schedules.rows(context, row)
        current = plan.find(&.exercise.starts_on.==(exercise.starts_on))
        depreciation, derogatory = posted[{row.id!.to_i64, key}]? || {ZERO, ZERO}
        Member.new(row, item, (current.try(&.accounting) || ZERO) - depreciation,
          (current.try(&.derogatory) || ZERO) - derogatory,
          Plan.disposal(Schedules.input(context, row), plan, item.price || ZERO))
      end
    end

    # Écriture de sortie (D-AMO-008) : dotation complémentaire jusqu'à la
    # date de sortie, dérogatoire de l'exercice puis reprise du cumul,
    # reprise des dépréciations, sortie de la valeur brute et des
    # amortissements ; en France valeur comptable des éléments cédés (675)
    # et produit de cession (775, créance 462) ; en Belgique plus-value
    # (763) ou moins-value (663) seule.
    def self.disposal_builder(context : Schedules::Context, members : Array(Member)) : Builder
      builder = Builder.new
      settings = context.settings
      be = context.regime == "be"
      members.each do |member|
        row = member.row
        result = member.result
        exercise = context.exercise_on(member.disposal.disposed_on!)
        label = I18n.t("amortis.entries.disposal", code: row.code.to_s, label: row.label.to_s)
        builder.pair(expense_account(context, row), row.depreciation_account.to_s, member.depreciation,
          I18n.t("amortis.entries.depreciation", exercise: exercise.display_label))
        unless be
          derogatory(context, builder, member.derogatory, exercise)
          if result.derogatory_cumul > 0
            builder.pair(settings.account("derogatory_account"), settings.account("derogatory_income_account"),
              result.derogatory_cumul, I18n.t("amortis.entries.derogatory_disposal", code: row.code.to_s))
          end
        end
        impairment_account = row.impairment_account.to_s
        builder.line(row.depreciation_account.to_s, Side::Debit, result.accounting_cumul, label)
        builder.line(row.asset_account.to_s, Side::Credit, result.gross, label)
        if be
          builder.line(impairment_account, Side::Debit, result.impairment_cumul, label)
          builder.line(settings.account("disposal_receivable_account"), Side::Debit, result.price, label)
          if result.result > 0
            builder.line(settings.account("disposal_income_account"), Side::Credit, result.result, label)
          elsif result.result < 0
            builder.line(settings.account("disposal_expense_account"), Side::Debit, -result.result, label)
          end
        else
          if result.impairment_cumul > 0
            builder.pair(impairment_account, settings.account("impairment_income_account"), result.impairment_cumul, label)
          end
          builder.line(settings.account("disposal_expense_account"), Side::Debit, result.gross - result.accounting_cumul, label)
          builder.pair(settings.account("disposal_receivable_account"), settings.account("disposal_income_account"),
            result.price, label)
        end
      end
      builder
    end

    def self.post_disposal(actor : Partiduo::Api::Actor, context : Schedules::Context, asset : Asset,
                           input : Api::PostInput) : Partiduo::Api::Result(Api::PostingView)
      failure = ->(errors : Array(FieldError)) { Partiduo::Api::Result(Api::PostingView).failure(errors) }
      disposal = context.disposal(asset.id!.to_i64)
      return failure.call([Records.error(FieldError::BASE, "disposal.none")]) if disposal.nil?
      return failure.call([Records.error(FieldError::BASE, "disposal.part_of_group")]) if disposal.parent_disposal_id
      if Records.live_posting(disposal_id: disposal.id!.to_i64)
        return failure.call([Records.error(FieldError::BASE, "disposal.posted")])
      end
      members = disposal_members(context, asset, disposal)
      builder = disposal_builder(context, members)
      errors = account_blockers(builder)
      ledger_id = resolve_ledger(context, input.ledger_id, errors)
      return failure.call(errors) unless errors.empty? && ledger_id
      exercise = context.exercise_on(disposal.disposed_on!)
      label = I18n.t("amortis.entries.disposal", code: asset.code.to_s, label: asset.label.to_s)
      post(actor, builder, ledger_id, disposal.disposed_on!, label, "#{SOURCE}disposal:#{disposal.id}", "disposal",
        exercise, asset, nil, disposal) do |posting|
        members.each do |member|
          PostingLine.create!(posting_id: posting.id, asset_id: member.row.id, exercise_start: exercise.starts_on,
            depreciation: member.depreciation, derogatory: member.derogatory, impairment: ZERO)
        end
      end
    end

    # --- Outils -----------------------------------------------------------------------

    private def self.post(actor : Partiduo::Api::Actor, builder : Builder, ledger_id : Int64, date : Time, label : String,
                          source : String, kind : String, exercise : Exercise, asset : Asset?, impairment : Impairment?,
                          disposal : Disposal?, & : Posting ->) : Partiduo::Api::Result(Api::PostingView)
      lines = builder.views.map { |line| Acc::EntryLineInput.new(line.account, line.side, line.amount, label: line.label) }
      entry_input = Acc::EntryInput.new(ledger_id: ledger_id, date: date, lines: lines, label: label[0, 200], source: source)
      Partiduo::Api::Transaction.run do
        result = Acc.post_entry(actor, entry_input)
        next Partiduo::Api::Result(Api::PostingView).failure(result.errors) if result.failure?
        entry = result.value!
        posting = Posting.create!(kind: kind, exercise_start: exercise.starts_on, exercise_end: exercise.ends_on,
          fiscal_year_id: exercise.fiscal_year_id, asset_id: asset.try(&.id), impairment_id: impairment.try(&.id),
          disposal_id: disposal.try(&.id), ledger_id: ledger_id, entry_id: entry.id, date: date,
          amount: builder.total_debit, status: "posted", created_by_id: actor.user_id)
        yield posting
        Partiduo::Api::Result(Api::PostingView).success(Records.posting_view(posting))
      end
    end

    def self.expense_account(context : Schedules::Context, row : Asset) : String
      row.expense_account.to_s.presence || context.settings.account("expense_account")
    end

    # Comptes cités absents du plan (ou non renseignés dans les réglages).
    def self.account_blockers(builder : Builder) : Array(FieldError)
      builder.accounts.compact_map do |number|
        if number.empty?
          Records.error(FieldError::BASE, "account.unset")
        elsif !Accounts.exists?(number)
          Records.error(FieldError::BASE, "account.missing", {"number" => number})
        end
      end.uniq!
    end

    def self.default_ledger_id(context : Schedules::Context) : Int64?
      context.settings.ledger_id ||
        Acc.ledgers(Records.system, Acc::LedgerKind::Misc, enabled_only: true).first?.try(&.id)
    end

    # Journal d'opérations diverses de l'écriture : donné, des réglages, ou
    # le premier ; erreur sur `ledger_id` sinon.
    def self.resolve_ledger(context : Schedules::Context, id : Int64?, errors : Array(FieldError)) : Int64?
      ledger_id = id || default_ledger_id(context)
      if ledger_id.nil?
        errors << Records.error("ledger_id", "ledger.blank")
        return
      end
      ledger = Acc.ledger(Records.system, ledger_id)
      unless ledger.kind.misc?
        errors << Records.error("ledger_id", "ledger.invalid")
        return
      end
      ledger_id
    rescue Partiduo::Api::NotFound
      errors << Records.error("ledger_id", "ledger.invalid")
      nil
    end

    # Annule une écriture d'inventaire par extourne (`cancel_entry`) ;
    # l'abonnement à `entry.cancelled` marque l'écriture annulée.
    def self.cancel(actor : Partiduo::Api::Actor, row : Posting, date : Time?) : Partiduo::Api::Result(Api::PostingView)
      return Partiduo::Api::Result(Api::PostingView).failure(Records.error(FieldError::BASE, "posting.cancelled")) if row.status == "cancelled"
      Partiduo::Api::Transaction.run do
        result = Acc.cancel_entry(actor, Acc::CancelEntryInput.new(row.entry_id!.to_i64, date))
        next Partiduo::Api::Result(Api::PostingView).failure(result.errors) if result.failure?
        Partiduo::Api::Result(Api::PostingView).success(Records.posting_view(Records.posting!(row.id!.to_i64)))
      end
    end
  end
end
