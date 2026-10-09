# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Ui
    # `/ext/AMORTIS/statements` : états d'un exercice (D-AMO-013,
    # D-AMO-014) — tableau des immobilisations (2054) et des amortissements
    # (2055, ventilation des dotations, dérogatoires) en France, état des
    # immobilisations en Belgique, registre de la 2035 (plan fiscal, plus ou
    # moins-values). Export CSV de chaque tableau (`part`) et PDF de l'état.
    class StatementsHandler < Handler
      KINDS = %w[statement register]

      def get
        exercise = chosen_exercise
        kind = KINDS.includes?(query("kind")) ? query("kind") : "statement"
        year = exercise.try(&.fiscal_year_id)
        params = {"year" => year.to_s, "kind" => kind}
        statement = year && kind == "statement" ? Api.statement(actor, year) : nil
        tables = if statement
                   statement_tables(statement, params)
                 elsif year
                   register_tables(Api.register(actor, year), params)
                 else
                   [] of {String, Table}
                 end
        if exercise && export?
          response = export(tables, exercise, I18n.t("amortis_ui.statements.#{kind}"))
          return response if response
        end
        unposted = statement.try(&.unposted)
        page("amortis/statements.html", {
          "title"        => I18n.t("amortis.menu.amortis_statements"),
          "crumbs"       => crumbs({I18n.t("amortis.menu.amortis_statements"), nil}),
          "actions"      => [] of Screen::Action,
          "exercises"    => exercise_options.map { |item| Ui.choice(item.value, item.label, item.value == year.to_s) },
          "kinds"        => KINDS.map { |code| Ui.choice(code, I18n.t("amortis_ui.statements.#{code}"), code == kind) },
          "tabs"         => KINDS.map { |code| Screen::Tab.new(I18n.t("amortis_ui.statements.#{code}"), "#{Ui.url("statements")}?year=#{year}&kind=#{code}", code == kind) },
          "kind"         => kind,
          "intro"        => I18n.t("amortis_ui.statements.intro_#{kind}"),
          "tables"       => tables.empty? ? nil : tables.map(&.[1]),
          "unposted"     => unposted.try { |amount| amount.zero? ? nil : fmt.amount(amount) },
          "postings_url" => "#{Ui.url("postings")}?year=#{year}",
          "pdf_url"      => "#{Ui.url("statements")}?year=#{year}&kind=#{kind}&format=pdf",
        })
      end

      # Export de l'état : PDF de tous les tableaux, ou CSV du tableau `part`.
      private def export(tables : Array({String, Table}), exercise : Api::ExerciseView, title : String) : Marten::HTTP::Response?
        name = I18n.t("amortis_ui.statements.csv_name")
        if pdf?
          return pdf_response(tables.map { |(_, table)| {table.caption.as(String?), table} }, "#{title} — #{exercise.label}",
            name, [I18n.t("amortis_ui.statements.exercise_summary", label: exercise.label)])
        end
        chosen = tables.find { |(part, _)| part == query("part") } || tables.first?
        chosen.try { |(part, table)| csv_response(table, "#{name}-#{part}") }
      end

      # Tableau d'une partie de l'état, une ligne par rubrique et le total.
      private def rubric_table(part : String, title : String, columns : Array(Table::Column), rows : Array(Api::StatementRowView),
                               params : Hash(String, String), & : Api::StatementRowView -> Array(BigDecimal)) : {String, Table}
        lines = rows.map do |row|
          cells = [Table::Cell.new(I18n.t(row.rubric_key))] + (yield row).map { |value| Present.money(fmt, value) }
          Table::Row.new(cells, row.rubric == "total" ? "pd-total" : "")
        end
        table = Table.new(title, columns, lines, Ui.url("statements"), params: params.merge({"part" => part}), id: "amo-#{part}")
        table.pdf = true
        {part, table}
      end

      private def statement_tables(view : Api::StatementView, params : Hash(String, String)) : Array({String, Table})
        rows = view.rows + [view.total]
        gross = [
          Table::Column.new("rubric", I18n.t("amortis_ui.statements.rubric"), sortable: false),
          Table::Column.new("opening", I18n.t("amortis_ui.statements.gross_opening"), "number", sortable: false),
          Table::Column.new("increase", I18n.t("amortis_ui.statements.gross_increase"), "number", sortable: false),
          Table::Column.new("decrease", I18n.t("amortis_ui.statements.gross_decrease"), "number", sortable: false),
          Table::Column.new("closing", I18n.t("amortis_ui.statements.gross_closing"), "number", sortable: false),
        ]
        depreciation = [
          Table::Column.new("rubric", I18n.t("amortis_ui.statements.rubric"), sortable: false),
          Table::Column.new("opening", I18n.t("amortis_ui.statements.depreciation_opening"), "number", sortable: false),
          Table::Column.new("charge", I18n.t("amortis_ui.statements.depreciation_charge"), "number", sortable: false),
          Table::Column.new("decrease", I18n.t("amortis_ui.statements.depreciation_decrease"), "number", sortable: false),
          Table::Column.new("closing", I18n.t("amortis_ui.statements.depreciation_closing"), "number", sortable: false),
          Table::Column.new("linear", I18n.t("amortis_ui.statements.charge_linear"), "number", sortable: false),
          Table::Column.new("degressive", I18n.t("amortis_ui.statements.charge_degressive"), "number", sortable: false),
          Table::Column.new("net", I18n.t("amortis_ui.statements.net_closing"), "number", sortable: false),
        ]
        impairment = [
          Table::Column.new("rubric", I18n.t("amortis_ui.statements.rubric"), sortable: false),
          Table::Column.new("opening", I18n.t("amortis_ui.statements.impairment_opening"), "number", sortable: false),
          Table::Column.new("charge", I18n.t("amortis_ui.statements.impairment_charge"), "number", sortable: false),
          Table::Column.new("release", I18n.t("amortis_ui.statements.impairment_release"), "number", sortable: false),
          Table::Column.new("closing", I18n.t("amortis_ui.statements.impairment_closing"), "number", sortable: false),
        ]
        derogatory = [
          Table::Column.new("rubric", I18n.t("amortis_ui.statements.rubric"), sortable: false),
          Table::Column.new("opening", I18n.t("amortis_ui.statements.derogatory_opening"), "number", sortable: false),
          Table::Column.new("charge_duration", I18n.t("amortis_ui.statements.derogatory_charge_duration"), "number", sortable: false),
          Table::Column.new("charge_degressive", I18n.t("amortis_ui.statements.derogatory_charge_degressive"), "number", sortable: false),
          Table::Column.new("release_duration", I18n.t("amortis_ui.statements.derogatory_release_duration"), "number", sortable: false),
          Table::Column.new("release_degressive", I18n.t("amortis_ui.statements.derogatory_release_degressive"), "number", sortable: false),
          Table::Column.new("closing", I18n.t("amortis_ui.statements.derogatory_closing"), "number", sortable: false),
        ]
        be = view.regime == "be"
        list = [
          rubric_table("gross", I18n.t(be ? "amortis_ui.statements.gross_title_be" : "amortis_ui.statements.gross_title"),
            gross, rows, params) { |row| [row.gross_opening, row.gross_increase, row.gross_decrease, row.gross_closing] },
          rubric_table("depreciation", I18n.t(be ? "amortis_ui.statements.depreciation_title_be" : "amortis_ui.statements.depreciation_title"),
            depreciation, rows, params) do |row|
            [row.depreciation_opening, row.depreciation_charge, row.depreciation_decrease, row.depreciation_closing,
             row.charge_linear, row.charge_degressive, row.net_closing]
          end,
          rubric_table("impairment", I18n.t("amortis_ui.statements.impairment_title"), impairment, rows, params) do |row|
            [row.impairment_opening, row.impairment_charge, row.impairment_release, row.impairment_closing]
          end,
        ]
        unless be
          list << rubric_table("derogatory", I18n.t("amortis_ui.statements.derogatory_title"), derogatory, rows, params) do |row|
            [row.derogatory_opening, row.derogatory_charge_duration, row.derogatory_charge_degressive,
             row.derogatory_release_duration, row.derogatory_release_degressive, row.derogatory_closing]
          end
        end
        list
      end

      private def register_tables(view : Api::RegisterView, params : Hash(String, String)) : Array({String, Table})
        columns = [
          Table::Column.new("code", I18n.t("amortis_ui.assets.code"), "mono"),
          Table::Column.new("label", I18n.t("amortis_ui.register.label")),
          Table::Column.new("acquired", I18n.t("amortis_ui.assets.acquired_on"), "mono"),
          Table::Column.new("base", I18n.t("amortis_ui.register.base"), "number"),
          Table::Column.new("method", I18n.t("amortis_ui.register.method")),
          Table::Column.new("rate", I18n.t("amortis_ui.register.rate"), "number"),
          Table::Column.new("prior", I18n.t("amortis_ui.register.prior"), "number"),
          Table::Column.new("charge", I18n.t("amortis_ui.register.charge"), "number"),
          Table::Column.new("net", I18n.t("amortis_ui.register.net"), "number"),
          Table::Column.new("disposed", I18n.t("amortis_ui.register.disposed_on"), "mono", secondary: true),
          Table::Column.new("price", I18n.t("amortis_ui.register.price"), "number", secondary: true),
          Table::Column.new("short_term", I18n.t("amortis_ui.register.short_term"), "number", secondary: true),
          Table::Column.new("long_term", I18n.t("amortis_ui.register.long_term"), "number", secondary: true),
        ]
        opt = ->(value : BigDecimal?) { value ? Present.money(fmt, value) : Table::Cell.new("") }
        rows = view.rows.map do |row|
          Table::Row.new([
            Table::Cell.new(row.code, Ui.url("asset", id: row.asset_id)), Table::Cell.new(row.label),
            Present.date(fmt, row.acquired_on), Present.money(fmt, row.base), Table::Cell.new(Present.mode(row.method)),
            Table::Cell.new(row.rate.try { |rate| fmt.percent(rate) } || ""), Present.money(fmt, row.prior),
            Present.money(fmt, row.charge), Present.money(fmt, row.net_value), Present.date(fmt, row.disposed_on),
            opt.call(row.price), opt.call(row.short_term), opt.call(row.long_term),
          ])
        end
        m = ->(value : BigDecimal) { Present.money(fmt, value) }
        footer = [Table::Row.new([Table::Cell.new(I18n.t("amortis.rubrics.total")), Table::Cell.new(""), Table::Cell.new(""),
                                  m.call(view.total_base), Table::Cell.new(""), Table::Cell.new(""), m.call(view.total_prior),
                                  m.call(view.total_charge), m.call(view.total_net), Table::Cell.new(""), Table::Cell.new(""),
                                  m.call(view.total_short_term), m.call(view.total_long_term)], "pd-total")]
        table = Table.new(I18n.t("amortis_ui.statements.register"), columns, rows, Ui.url("statements"),
          params: params.merge({"part" => "register"}), empty_message: I18n.t("amortis_ui.register.none"),
          id: "amo-register", footer_rows: footer)
        table.pdf = true
        [{"register", table}]
      end
    end

    # `/ext/AMORTIS/coefficients` : coefficients datés du dégressif fiscal
    # français (D-AMO-006).
    class CoefficientsHandler < Handler
      def get
        columns = [
          Table::Column.new("from", I18n.t("amortis_ui.coefficients.from"), "mono"),
          Table::Column.new("before", I18n.t("amortis_ui.coefficients.before"), "mono"),
          Table::Column.new("short", I18n.t("amortis_ui.coefficients.short"), "number"),
          Table::Column.new("medium", I18n.t("amortis_ui.coefficients.medium"), "number"),
          Table::Column.new("long", I18n.t("amortis_ui.coefficients.long"), "number"),
          Table::Column.new("source", I18n.t("amortis_ui.coefficients.source")),
        ]
        rows = Api.coefficients(actor).map do |item|
          Table::Row.new([Present.date(fmt, item.from), Present.date(fmt, item.before),
                          Table::Cell.new(fmt.number(item.short), sort: item.short), Table::Cell.new(fmt.number(item.medium), sort: item.medium),
                          Table::Cell.new(fmt.number(item.long), sort: item.long),
                          Table::Cell.new(I18n.t("amortis.coefficient_sources.#{item.source}"))])
        end
        table = Table.new(I18n.t("amortis_ui.coefficients.title"), columns, rows, Ui.url("coefficients"), id: "amo-coefficients")
        list_page(I18n.t("amortis_ui.coefficients.title"), table, crumbs({I18n.t("amortis_ui.coefficients.title"), nil}),
          "amortis_ui.coefficients.csv_name", intro: I18n.t("amortis_ui.coefficients.intro"), filter: false)
      end
    end

    # `/ext/AMORTIS/settings` : réglages (`amortis.admin`, D-AMO-011).
    class SettingsHandler < Handler
      def get
        show(form(values_of(Api.settings(actor))))
      end

      def post
        values = (["ledger_id", "day_count", "be_individual"] + Api::DEFAULT_ACCOUNTS).to_h { |name| {name, field(name)} }
        form = form(values)
        input = Api::SettingsInput.new(ledger_id: id_field("ledger_id"), day_count: field("day_count"),
          expense_account: field("expense_account"), impairment_expense_account: field("impairment_expense_account"),
          impairment_income_account: field("impairment_income_account"), derogatory_account: field("derogatory_account"),
          derogatory_expense_account: field("derogatory_expense_account"),
          derogatory_income_account: field("derogatory_income_account"),
          disposal_expense_account: field("disposal_expense_account"), disposal_income_account: field("disposal_income_account"),
          disposal_receivable_account: field("disposal_receivable_account"), be_individual: field("be_individual") == "1")
        result = Api.update_settings(actor, input)
        if result.success?
          flash["success"] = I18n.t("amortis_ui.flash.saved")
          return go(Ui.url("settings"))
        end
        form.add_errors(result.errors, fmt)
        show(form)
      end

      private def values_of(view : Api::SettingsView) : Hash(String, String)
        values = {"ledger_id" => view.ledger_id.to_s, "day_count" => view.day_count, "be_individual" => view.be_individual ? "1" : ""}
        Api::DEFAULT_ACCOUNTS.each { |code| values[code] = view.account(code) }
        values
      end

      private def form(values : Hash(String, String)) : Form
        settings = Api.settings(actor)
        general = [
          Form::Field.new("ledger_id", I18n.t("amortis_ui.settings.ledger"), "select", values["ledger_id"]? || "",
            options: [blank_option("amortis_ui.settings.first_ledger")] + ledger_options, help: I18n.t("amortis_ui.settings.ledger_help")),
          Form::Field.new("day_count", I18n.t("amortis_ui.settings.day_count"), "select", values["day_count"]? || "actual",
            options: code_options(Api::DAY_COUNTS, "amortis.day_counts"), help: I18n.t("amortis_ui.settings.day_count_help")),
        ]
        if settings.regime == "be"
          general << Form::Field.new("be_individual", I18n.t("amortis_ui.settings.be_individual"), "checkbox",
            values["be_individual"]? || "", help: I18n.t("amortis_ui.settings.be_individual_help"))
        end
        codes = settings.regime == "be" ? Api::DEFAULT_ACCOUNTS.reject(&.starts_with?("derogatory")) : Api::DEFAULT_ACCOUNTS
        accounts = codes.map do |code|
          Form::Field.new(code, I18n.t("amortis.default_accounts.#{code}"), value: values[code]? || "", mono: true, maxlength: 40)
        end
        Form.new([Form::Group.new(nil, general), Form::Group.new(I18n.t("amortis_ui.settings.accounts"), accounts)])
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("amortis.menu.amortis_settings")
        actions = [post_action("amortis_ui.settings.create_accounts", Ui.url("settings_accounts"), nil, "", "plus"),
                   link_action("amortis_ui.coefficients.title", Ui.url("coefficients"), "", "percent")]
        form_page(title, settings_crumbs({title, nil}), form, Ui.url("settings"), I18n.t("ui.forms.save"), nil, actions,
          intro: I18n.t("amortis_ui.settings.intro"))
      end
    end

    # Crée les comptes des réglages absents du plan (`Api.ensure_accounts`).
    class SettingsAccountsHandler < Handler
      def get
        go(Ui.url("settings"))
      end

      def post
        result = Api.ensure_accounts(actor)
        if result.success?
          created = result.value!
          flash["success"] = created.empty? ? I18n.t("amortis_ui.flash.accounts_present") : I18n.t("amortis_ui.flash.accounts_created", numbers: created.join(", "))
        else
          flash["danger"] = messages(result)
        end
        go(Ui.url("settings"))
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(Ui.url("settings"))
      end
    end
  end
end
