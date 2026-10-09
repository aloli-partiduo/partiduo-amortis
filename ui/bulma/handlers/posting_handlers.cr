# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Ui
    module Present
      def self.posting_columns : Array(Table::Column)
        [
          Table::Column.new("date", I18n.t("amortis_ui.postings.date"), "mono"),
          Table::Column.new("kind", I18n.t("amortis_ui.postings.kind")),
          Table::Column.new("exercise", I18n.t("amortis_ui.postings.exercise"), secondary: true),
          Table::Column.new("asset", I18n.t("amortis_ui.postings.asset"), "mono", secondary: true),
          Table::Column.new("amount", I18n.t("amortis_ui.postings.amount"), "number"),
          Table::Column.new("entry", I18n.t("amortis_ui.postings.entry"), "mono"),
          Table::Column.new("status", I18n.t("amortis_ui.postings.status")),
          Table::Column.new("actions", I18n.t("amortis_ui.candidates.actions"), "actions", sortable: false),
        ]
      end

      def self.posting_row(view : Api::PostingView, fmt : PartiduoUi::Format, can_cancel : Bool) : Table::Row
        actions = [] of PartiduoUi::Screen::Action
        if can_cancel
          actions << PartiduoUi::Screen::Action.new(I18n.t("amortis_ui.postings.cancel"), Ui.url("posting_cancel", id: view.id),
            "post", "danger", "undo-2", I18n.t("amortis_ui.postings.cancel_confirm"))
        end
        Table::Row.new([
          date(fmt, view.date),
          Table::Cell.new(I18n.t(view.kind_key)),
          Table::Cell.new(view.exercise.label),
          Table::Cell.new(view.asset_code || "", view.asset_id.try { |id| Ui.url("asset", id: id) }),
          money(fmt, view.amount),
          Table::Cell.new(view.entry_id.to_s, Ui.entry_url(view.entry_id)),
          Table::Cell.new(I18n.t(view.status_key)),
          Table::Cell.new("", actions: actions),
        ], view.cancelled? ? "amo-cancelled" : "")
      end
    end

    # `/ext/AMORTIS/postings` : écritures d'inventaire (D-AMO-009). Pour
    # l'exercice choisi : dotations proposées (par immobilisation), écriture
    # qui en résulte, obstacles (comptes absents), sorties et dépréciations
    # de l'exercice dont l'écriture reste à passer ; formulaire pour passer
    # l'écriture ; écritures passées, extournables.
    class PostingsHandler < Handler
      def get
        render_page
      end

      def render_page(error : String? = nil, status : Int32 = 200) : Marten::HTTP::Response
        exercise = chosen_exercise
        proposal = exercise.try { |item| item.fiscal_year_id.try { |id| Api.proposal(actor, id) } }
        path = Ui.url("postings")
        lines = proposal.try do |view|
          rows = view.lines.map do |line|
            url = Ui.url("asset", id: line.asset_id)
            Table::Row.new([Table::Cell.new(line.code, url), Table::Cell.new(line.label, url),
                            Present.money(fmt, line.depreciation), Present.money(fmt, line.derogatory),
                            Table::Cell.new(Present.mode(line.accounting_mode)),
                            Table::Cell.new("#{line.expense_account} / #{line.depreciation_account}")])
          end
          columns = [
            Table::Column.new("code", I18n.t("amortis_ui.assets.code"), "mono"),
            Table::Column.new("label", I18n.t("amortis_ui.assets.label")),
            Table::Column.new("depreciation", I18n.t("amortis_ui.proposal.depreciation"), "number"),
            Table::Column.new("derogatory", I18n.t("amortis_ui.proposal.derogatory"), "number"),
            Table::Column.new("mode", I18n.t("amortis_ui.schedule.mode"), secondary: true),
            Table::Column.new("accounts", I18n.t("amortis_ui.proposal.accounts"), "mono", secondary: true),
          ]
          footer = [Table::Row.new([Table::Cell.new(I18n.t("amortis.rubrics.total")), Table::Cell.new(""),
                                    Present.money(fmt, view.total_depreciation), Present.money(fmt, view.total_derogatory),
                                    Table::Cell.new(""), Table::Cell.new("")], "pd-total")]
          table = Table.new(I18n.t("amortis_ui.proposal.title"), columns, rows, path,
            params: {"year" => view.exercise.fiscal_year_id.to_s}, empty_message: I18n.t("amortis_ui.proposal.none"),
            id: "amo-proposal", footer_rows: footer)
          table.exportable = false
          table
        end
        history = Api.postings(actor, exercise.try(&.fiscal_year_id)).map do |item|
          Present.posting_row(item, fmt, can_write? && !item.cancelled?)
        end
        posted = Table.new(I18n.t("amortis_ui.postings.history"), Present.posting_columns, history, path,
          empty_message: I18n.t("amortis_ui.postings.none"), id: "amo-postings")
        posted.exportable = false
        page("amortis/postings.html", {
          "title"        => I18n.t("amortis.menu.amortis_postings"),
          "crumbs"       => crumbs({I18n.t("amortis.menu.amortis_postings"), nil}),
          "actions"      => [] of Screen::Action,
          "exercises"    => exercise_options.map { |item| Ui.choice(item.value, item.label, item.value == exercise.try(&.fiscal_year_id).to_s) },
          "exercise"     => exercise.try(&.label),
          "closed"       => Ui.flag(exercise.try(&.closed) || false),
          "lines"        => lines,
          "entry"        => proposal.try { |view| view.empty? ? nil : Present.entry_lines_table(view.entry_lines, fmt, path, "amo-proposal-entry") },
          "blockers"     => proposal.try { |view| view.blockers.empty? ? nil : view.blockers.map { |item| fmt.message(item) } },
          "disposals"    => proposal.try { |view| view.disposals.empty? ? nil : view.disposals.map { |item| Ui.row({"code" => item.code, "label" => item.label, "url" => Ui.url("asset", id: item.id)}) } },
          "impairments"  => proposal.try { |view| view.impairments.empty? ? nil : view.impairments.map { |item| Ui.row({"date" => fmt.date(item.date), "amount" => fmt.amount(item.amount), "url" => Ui.url("asset", id: item.asset_id)}) } },
          "can_post"     => Ui.flag(can_write? && !proposal.nil? && !proposal.empty? && proposal.blockers.empty?),
          "post_url"     => Ui.url("postings_post"),
          "year"         => exercise.try(&.fiscal_year_id).to_s,
          "ledgers"      => ledger_options.map { |item| Ui.choice(item.value, item.label, item.value == proposal.try(&.ledger_id).to_s) },
          "date"         => (proposal.try(&.date) || Partiduo::Api::Core.today).to_s("%F"),
          "history"      => posted,
          "error"        => error,
          "settings_url" => can_admin? ? Ui.url("settings") : nil,
        }, status: status)
      end
    end

    # Passe l'écriture des dotations proposées (`Api.post_depreciation`).
    class PostingsPostHandler < PostingsHandler
      def get
        go(Ui.url("postings"))
      end

      def post
        year = id_field("year") || return go(Ui.url("postings"))
        day = date_field("date")
        input = Api::PostInput.new(ledger_id: id_field("ledger_id"), date: day)
        result = Api.post_depreciation(actor, year, input)
        if result.failure?
          flash["danger"] = messages(result)
          return go("#{Ui.url("postings")}?year=#{year}")
        end
        flash["success"] = I18n.t("amortis_ui.flash.posted")
        go("#{Ui.url("postings")}?year=#{year}")
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(Ui.url("postings"))
      end
    end

    # Extourne une écriture d'inventaire (`Api.cancel_posting`).
    class PostingCancelHandler < Handler
      def get
        go(Ui.url("postings"))
      end

      def post
        view = Api.posting(actor, id_param)
        back = PartiduoUi::Navigation.safe_path(request.headers["Referer"]?.try { |referer| URI.parse(referer).request_target }) ||
               "#{Ui.url("postings")}?year=#{view.exercise.fiscal_year_id}"
        after(Api.cancel_posting(actor, view.id), "amortis_ui.flash.cancelled", back)
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(Ui.url("postings"))
      end
    end
  end
end
