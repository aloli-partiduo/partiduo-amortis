# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Ui
    # `/ext/AMORTIS/assets` : registre des immobilisations (D-AMO-003) —
    # numéro, désignation, rubrique, acquisition, valeur brute, mode et
    # durée, valeur nette, état ; composants sous leur immobilisation. Liste
    # triable, filtrable par état et exportable.
    class AssetsHandler < Handler
      TABS = %w[all in_service pending depreciated disposed]

      def get
        status = query("status").presence.try { |value| TABS.includes?(value) ? value : nil } || "all"
        views = Api.assets(actor, Api::AssetQuery.new(status: status == "all" ? nil : status, limit: Api::MAX_LIMIT))
        columns = [
          Table::Column.new("code", I18n.t("amortis_ui.assets.code"), "mono"),
          Table::Column.new("label", I18n.t("amortis_ui.assets.label")),
          Table::Column.new("rubric", I18n.t("amortis_ui.assets.rubric"), secondary: true),
          Table::Column.new("acquired", I18n.t("amortis_ui.assets.acquired_on"), "mono"),
          Table::Column.new("gross", I18n.t("amortis_ui.assets.gross_value"), "number"),
          Table::Column.new("method", I18n.t("amortis_ui.assets.method"), secondary: true),
          Table::Column.new("net", I18n.t("amortis_ui.assets.net_value"), "number"),
          Table::Column.new("status", I18n.t("amortis_ui.assets.status")),
        ]
        rows = views.map do |view|
          url = Ui.url("asset", id: view.id)
          label = view.component? ? I18n.t("amortis_ui.assets.component_of", label: view.label, parent: view.parent_code) : view.label
          Table::Row.new([
            Table::Cell.new(view.code, url),
            Table::Cell.new(label, url),
            Table::Cell.new(I18n.t(view.rubric_key)),
            Present.date(fmt, view.acquired_on),
            Present.money(fmt, view.gross_value),
            Table::Cell.new("#{I18n.t(view.method_key)} #{Ui.duration(view.life_months)}".strip),
            Present.money(fmt, view.net_value),
            Table::Cell.new(I18n.t(view.status_key)),
          ])
        end
        table = Table.new(I18n.t("amortis.menu.amortis_assets"), columns, rows, Ui.url("assets"),
          params: status == "all" ? {} of String => String : {"status" => status},
          empty_message: I18n.t("amortis_ui.assets.none"), id: "amo-assets")
        tabs = TABS.map do |code|
          url = code == "all" ? Ui.url("assets") : "#{Ui.url("assets")}?status=#{code}"
          Screen::Tab.new(I18n.t("amortis_ui.assets.tabs.#{code}"), url, code == status)
        end
        actions = [] of Screen::Action
        actions << link_action("amortis_ui.assets.new", Ui.url("asset_new"), "primary", "plus") if can_write?
        actions << link_action("amortis_ui.candidates.title", Ui.url("candidates"), "", "file-text")
        list_page(I18n.t("amortis.menu.amortis_assets"), table, crumbs({I18n.t("amortis.menu.amortis_assets"), nil}),
          "amortis_ui.assets.csv_name", actions, tabs: tabs, tabs_label: I18n.t("amortis_ui.assets.tabs_label"),
          intro: I18n.t("amortis_ui.assets.intro"))
      end
    end

    # Formulaire d'une immobilisation (création, modification), avec
    # l'aperçu du plan rendu en HTMX à chaque changement (`asset_preview`).
    abstract class AssetScreen < Handler
      FIELDS = %w[code label parent_id card_code notes asset_account depreciation_account impairment_account expense_account
        acquired_on in_service_on gross_value residual_value new_asset method life_years fiscal_method fiscal_life_years
        entry_line_id]

      @settings : Api::SettingsView?

      def settings : Api::SettingsView
        @settings ||= Api.settings(actor)
      end

      def values_of(view : Api::AssetView) : Hash(String, String)
        {
          "code" => view.code, "label" => view.label, "parent_id" => view.parent_id.to_s, "card_code" => view.card_code,
          "notes" => view.notes, "asset_account" => view.asset_account, "depreciation_account" => view.depreciation_account,
          "impairment_account" => view.impairment_account,
          "expense_account" => view.expense_account_default ? "" : view.expense_account,
          "acquired_on" => view.acquired_on.to_s("%F"), "in_service_on" => view.in_service_on.try(&.to_s("%F")) || "",
          "gross_value" => fmt.input_number(view.gross_value), "residual_value" => fmt.input_number(view.residual_value),
          "new_asset" => view.new_asset ? "1" : "", "method" => view.method, "life_years" => years_value(view.life_months),
          "fiscal_method" => view.fiscal_method, "fiscal_life_years" => years_value(view.fiscal_life_months),
          "entry_line_id" => view.entry_line_id.to_s,
        }
      end

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name)} }
      end

      def parent_options(exclude : Int64? = nil) : Array(Form::Option)
        list = Api.assets(actor, Api::AssetQuery.new(include_components: false, limit: Api::MAX_LIMIT))
          .reject { |view| view.id == exclude || view.disposed? }
          .map { |view| option(view.id.to_s, "#{view.code} · #{view.label}") }
        [blank_option("amortis_ui.form.no_parent")] + list
      end

      def asset_form(values : Hash(String, String), exclude : Int64? = nil) : Form
        value = ->(name : String) { values[name]? || "" }
        general = [
          Form::Field.new("label", I18n.t("amortis_ui.assets.label"), value: value.call("label"), required: true, maxlength: 255),
          Form::Field.new("code", I18n.t("amortis_ui.assets.code"), value: value.call("code"), maxlength: 30, mono: true,
            help: I18n.t("amortis_ui.form.code_help")),
          Form::Field.new("parent_id", I18n.t("amortis_ui.form.parent"), "select", value.call("parent_id"),
            options: parent_options(exclude), help: I18n.t("amortis_ui.form.parent_help")),
          Form::Field.new("card_code", I18n.t("amortis_ui.form.card"), value: value.call("card_code"), maxlength: 64, mono: true),
          Form::Field.new("notes", I18n.t("amortis_ui.form.notes"), "textarea", value.call("notes"), wide: true, maxlength: 4000),
          Form::Field.new("entry_line_id", "", "hidden", value.call("entry_line_id")),
        ]
        accounts = [
          Form::Field.new("asset_account", I18n.t("amortis_ui.form.asset_account"), value: value.call("asset_account"),
            required: true, mono: true, maxlength: 40, help: I18n.t("amortis_ui.form.asset_account_help")),
          Form::Field.new("depreciation_account", I18n.t("amortis_ui.form.depreciation_account"),
            value: value.call("depreciation_account"), mono: true, maxlength: 40, help: I18n.t("amortis_ui.form.derived_help")),
          Form::Field.new("impairment_account", I18n.t("amortis_ui.form.impairment_account"),
            value: value.call("impairment_account"), mono: true, maxlength: 40, help: I18n.t("amortis_ui.form.derived_help")),
          Form::Field.new("expense_account", I18n.t("amortis_ui.form.expense_account"), value: value.call("expense_account"),
            mono: true, maxlength: 40,
            help: I18n.t("amortis_ui.form.expense_help", number: settings.account("expense_account"))),
        ]
        amounts = [
          Form::Field.new("acquired_on", I18n.t("amortis_ui.assets.acquired_on"), "date", value.call("acquired_on"), required: true),
          Form::Field.new("in_service_on", I18n.t("amortis_ui.assets.in_service_on"), "date", value.call("in_service_on"),
            help: I18n.t("amortis_ui.form.in_service_help")),
          Form::Field.new("gross_value", I18n.t("amortis_ui.assets.gross_value"), "number", value.call("gross_value"),
            required: true, mono: true, help: I18n.t("amortis_ui.form.gross_help")),
          Form::Field.new("residual_value", I18n.t("amortis_ui.form.residual_value"), "number", value.call("residual_value"),
            mono: true),
          Form::Field.new("new_asset", I18n.t("amortis_ui.form.new_asset"), "checkbox", value.call("new_asset")),
        ]
        plan = [
          Form::Field.new("method", I18n.t("amortis_ui.assets.method"), "select", value.call("method"),
            options: code_options(Api::METHODS, "amortis.methods"), required: true),
          Form::Field.new("life_years", I18n.t("amortis_ui.form.life_years"), "number", value.call("life_years"), mono: true,
            help: I18n.t("amortis_ui.form.life_help")),
        ]
        groups = [Form::Group.new(nil, general), Form::Group.new(I18n.t("amortis_ui.form.accounts"), accounts),
                  Form::Group.new(I18n.t("amortis_ui.form.values"), amounts), Form::Group.new(I18n.t("amortis_ui.form.plan"), plan)]
        if settings.regime == "fr"
          fiscal = [
            Form::Field.new("fiscal_method", I18n.t("amortis_ui.form.fiscal_method"), "select", value.call("fiscal_method"),
              options: code_options(Api::FISCAL_METHODS, "amortis.fiscal_methods")),
            Form::Field.new("fiscal_life_years", I18n.t("amortis_ui.form.fiscal_life_years"), "number",
              value.call("fiscal_life_years"), mono: true, help: I18n.t("amortis_ui.form.fiscal_help")),
          ]
          groups << Form::Group.new(I18n.t("amortis_ui.form.fiscal"), fiscal)
        end
        Form.new(groups)
      end

      # Saisie lue ; `nil` et des erreurs de formulaire si une date, un
      # montant ou une durée est illisible.
      def read_input(form : Form) : Api::AssetInput?
        acquired = date_value(form, "acquired_on", required: true)
        service = date_value(form, "in_service_on")
        gross = decimal_value(form, "gross_value", required: true)
        residual = decimal_value(form, "residual_value") || BigDecimal.new(0)
        life = months_value(form, "life_years")
        fiscal_life = months_value(form, "fiscal_life_years")
        return if form.invalid || acquired.nil? || gross.nil?
        Api::AssetInput.new(label: field("label"), asset_account: field("asset_account"), acquired_on: acquired,
          gross_value: gross, code: field("code"), in_service_on: service, residual_value: residual,
          method: field("method").presence || "linear", life_months: life || 0,
          fiscal_method: field("fiscal_method").presence || "same", fiscal_life_months: fiscal_life,
          new_asset: field("new_asset") == "1", depreciation_account: field("depreciation_account"),
          impairment_account: field("impairment_account"), expense_account: field("expense_account"),
          parent_id: id_field("parent_id"), card_code: field("card_code"), entry_line_id: id_field("entry_line_id"),
          notes: field("notes", strip: false).strip)
      end

      # Date lue ; erreur de formulaire si elle est illisible (ou absente et
      # exigée).
      private def date_value(form : Form, name : String, required : Bool = false) : Time?
        value = date_field(name)
        if value.nil? && (required || !field(name).empty?)
          form.add_error(name, I18n.t("ui.forms.invalid_date"))
        end
        value
      end

      private def decimal_value(form : Form, name : String, required : Bool = false) : BigDecimal?
        value = decimal_field(name)
        if value.nil? && (required || !field(name).empty?)
          form.add_error(name, I18n.t("ui.forms.invalid_number"))
        end
        value
      end

      private def months_value(form : Form, name : String) : Int32?
        value = months_field(name)
        form.add_error(name, I18n.t("ui.forms.invalid_number")) if value.nil? && !field(name).empty?
        value
      end

      # Erreurs du contrat rangées sous les champs de l'écran (durées en
      # années).
      def add_errors(form : Form, errors : Array(Partiduo::Api::FieldError)) : Nil
        errors.each do |error|
          name = {"life_months" => "life_years", "fiscal_life_months" => "fiscal_life_years"}[error.field]? || error.field
          form.add_error(name, fmt.message(error))
        end
      end

      def show_form(title : String, crumbs : Array(Screen::Crumb), form : Form, action : String, submit : String,
                    cancel : String, preview : Array(Api::ScheduleRowView)? = nil,
                    actions = [] of Screen::Action) : Marten::HTTP::Response
        page("amortis/asset_form.html", {
          "title"        => title,
          "crumbs"       => crumbs,
          "actions"      => actions,
          "form"         => form,
          "form_action"  => action,
          "form_submit"  => submit,
          "cancel_url"   => cancel,
          "preview_url"  => Ui.url("asset_preview"),
          "preview"      => preview.try { |rows| Present.schedule_table(rows, settings.regime == "fr", fmt, Ui.url("asset_preview"), false, "amo-preview-table") },
          "intro"        => I18n.t("amortis_ui.form.intro"),
          "coefficients" => Ui.url("coefficients"),
        }, status: form.invalid || form.base_errors ? 422 : 200)
      end
    end

    class AssetNewHandler < AssetScreen
      def get
        values = {"method" => "linear", "fiscal_method" => "same", "new_asset" => "1", "residual_value" => "0"}
        if parent = query("parent").to_i64?
          view = Api.asset(actor, parent)
          values.merge!({"parent_id" => view.id.to_s, "asset_account" => view.asset_account,
                         "acquired_on" => view.acquired_on.to_s("%F"),
                         "in_service_on" => view.in_service_on.try(&.to_s("%F")) || ""})
        end
        if line = query("line").to_i64?
          if candidate = Api.candidates(actor).find(&.line_id.==(line))
            values.merge!({"entry_line_id" => line.to_s, "asset_account" => candidate.account, "label" => candidate.label,
                           "acquired_on" => candidate.date.to_s("%F"), "in_service_on" => candidate.date.to_s("%F"),
                           "gross_value" => fmt.input_number(candidate.amount)})
          end
        end
        show(asset_form(values))
      end

      def post
        form = asset_form(submitted)
        if input = read_input(form)
          result = Api.create_asset(actor, input)
          if result.success?
            flash["success"] = I18n.t("amortis_ui.flash.created", code: result.value!.code)
            return go(Ui.url("asset", id: result.value!.id))
          end
          add_errors(form, result.errors)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("amortis_ui.assets.new")
        show_form(title, crumbs({I18n.t("amortis.menu.amortis_assets"), Ui.url("assets")}, {title, nil}), form,
          Ui.url("asset_new"), I18n.t("ui.forms.create"), Ui.url("assets"))
      end
    end

    class AssetEditHandler < AssetScreen
      def get
        view = Api.asset(actor, id_param)
        show(view, asset_form(values_of(view), view.id))
      end

      def post
        view = Api.asset(actor, id_param)
        form = asset_form(submitted, view.id)
        if input = read_input(form)
          result = Api.update_asset(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("amortis_ui.flash.saved")
            return go(Ui.url("asset", id: view.id))
          end
          add_errors(form, result.errors)
        end
        show(view, form)
      end

      private def show(view : Api::AssetView, form : Form) : Marten::HTTP::Response
        title = "#{view.code} · #{view.label}"
        list = crumbs({I18n.t("amortis.menu.amortis_assets"), Ui.url("assets")}, {view.code, Ui.url("asset", id: view.id)},
          {I18n.t("amortis_ui.assets.edit"), nil})
        show_form(title, list, form, Ui.url("asset_edit", id: view.id), I18n.t("ui.forms.save"), Ui.url("asset", id: view.id))
      end
    end

    # Aperçu du plan d'une saisie (HTMX) : le tableau seul, ou les erreurs
    # du plan.
    class AssetPreviewHandler < AssetScreen
      def get
        go(Ui.url("assets"))
      end

      def post
        form = asset_form(submitted)
        input = read_input(form)
        rows = nil
        errors = [] of String
        if input
          result = Api.preview_schedule(actor, input)
          result.success? ? (rows = result.value!) : (errors = result.errors.map { |error| fmt.message(error) })
        end
        page("amortis/_preview.html", {
          "preview" => rows.try { |list| Present.schedule_table(list, settings.regime == "fr", fmt, Ui.url("asset_preview"), false, "amo-preview-table") },
          "errors"  => errors.empty? ? nil : errors,
        })
      end
    end

    class AssetDeleteHandler < Handler
      def get
        go(Ui.url("asset", id: id_param))
      end

      def post
        result = Api.delete_asset(actor, id_param)
        return after(result, "amortis_ui.flash.deleted", Ui.url("assets")) if result.success?
        after(result, "amortis_ui.flash.deleted", Ui.url("asset", id: id_param))
      end
    end

    # `/ext/AMORTIS/candidates` : acquisitions à inscrire (D-AMO-004).
    class CandidatesHandler < Handler
      def get
        columns = [
          Table::Column.new("date", I18n.t("amortis_ui.candidates.date"), "mono"),
          Table::Column.new("ledger", I18n.t("amortis_ui.candidates.ledger"), "mono", secondary: true),
          Table::Column.new("receipt", I18n.t("amortis_ui.candidates.receipt"), "mono", secondary: true),
          Table::Column.new("label", I18n.t("amortis_ui.candidates.label")),
          Table::Column.new("account", I18n.t("amortis_ui.candidates.account"), "mono"),
          Table::Column.new("amount", I18n.t("amortis_ui.candidates.amount"), "number"),
          Table::Column.new("actions", I18n.t("amortis_ui.candidates.actions"), "actions", sortable: false),
        ]
        rows = Api.candidates(actor).map do |view|
          actions = can_write? ? [link_action("amortis_ui.candidates.register", "#{Ui.url("asset_new")}?line=#{view.line_id}", "primary", "plus")] : [] of Screen::Action
          Table::Row.new([
            Present.date(fmt, view.date),
            Table::Cell.new(view.ledger_code, Ui.entry_url(view.entry_id)),
            Table::Cell.new(view.receipt || ""),
            Table::Cell.new(view.label),
            Table::Cell.new("#{view.account} · #{view.account_label}"),
            Present.money(fmt, view.amount),
            Table::Cell.new("", actions: actions),
          ])
        end
        table = Table.new(I18n.t("amortis_ui.candidates.title"), columns, rows, Ui.url("candidates"),
          empty_message: I18n.t("amortis_ui.candidates.none"), id: "amo-candidates")
        list_page(I18n.t("amortis_ui.candidates.title"), table, crumbs({I18n.t("amortis_ui.candidates.title"), nil}),
          "amortis_ui.candidates.csv_name", intro: I18n.t("amortis_ui.candidates.intro"))
      end
    end
  end
end
