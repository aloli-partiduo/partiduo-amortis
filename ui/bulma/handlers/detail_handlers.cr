# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Ui
    # `/ext/AMORTIS/assets/<id>` : fiche d'une immobilisation — valeurs et
    # comptes, tableau d'amortissement (exportable), composants,
    # dépréciations (saisie, écriture), sortie (saisie, écriture proposée,
    # écriture), écritures d'inventaire qui la citent.
    class AssetDetailHandler < Handler
      def get
        render_detail(id_param)
      end

      def render_detail(id : Int64, errors = {} of String => Array(String), values = {} of String => String,
                        status : Int32 = 200) : Marten::HTTP::Response
        schedule = Api.schedule(actor, id)
        view = schedule.asset
        table = Present.schedule_table(schedule.rows, schedule.derogatory, fmt, Ui.url("asset", id: id))
        if export?
          name = "#{I18n.t("amortis_ui.schedule.csv_name")}-#{view.code}"
          return pdf? ? pdf_response([{nil.as(String?), table}], "#{view.code} · #{view.label}", name) : csv_response(table, name)
        end
        page("amortis/asset_detail.html", {
          "title"             => "#{view.code} · #{view.label}",
          "crumbs"            => crumbs({I18n.t("amortis.menu.amortis_assets"), Ui.url("assets")}, {view.code, nil}),
          "actions"           => detail_actions(view),
          "status"            => I18n.t(view.status_key),
          "status_class"      => Ui.status_class(view.status),
          "facts"             => facts(view),
          "schedule"          => table,
          "components"        => components_table(view),
          "can_component"     => Ui.flag(can_write? && !view.component? && !view.disposed?),
          "component_url"     => "#{Ui.url("asset_new")}?parent=#{view.id}",
          "impairments"       => impairments_table(view),
          "impairment"        => impairment_form(view, errors, values),
          "impairment_url"    => Ui.url("impairment_add", id: view.id),
          "impairment_submit" => I18n.t("amortis_ui.impairments.add"),
          "disposal"          => view.disposal.try { |item| disposal_facts(view, item) },
          "disposal_entry"    => disposal_entry(view),
          "disposal_actions"  => disposal_actions(view),
          "dispose"           => dispose_form(view, errors, values),
          "dispose_url"       => Ui.url("dispose", id: view.id),
          "dispose_submit"    => I18n.t("amortis_ui.disposal.submit"),
          "postings"          => postings_table(view),
          "locked"            => Ui.flag(view.locked),
        }, status: status)
      end

      private def detail_actions(view : Api::AssetView) : Array(Screen::Action)
        actions = [] of Screen::Action
        return actions unless can_write?
        actions << link_action("amortis_ui.assets.edit", Ui.url("asset_edit", id: view.id), "", "pencil")
        unless view.locked
          actions << post_action("amortis_ui.assets.delete", Ui.url("asset_delete", id: view.id),
            "amortis_ui.assets.delete_confirm", "danger", "x")
        end
        actions
      end

      private def facts(view : Api::AssetView) : Array(Screen::Item)
        items = [
          Screen::Item.new(I18n.t("amortis_ui.assets.rubric"), I18n.t(view.rubric_key)),
          Screen::Item.new(I18n.t("amortis_ui.form.asset_account"), view.asset_account, mono: true),
          Screen::Item.new(I18n.t("amortis_ui.form.depreciation_account"), view.depreciation_account, mono: true),
          Screen::Item.new(I18n.t("amortis_ui.form.impairment_account"), view.impairment_account, mono: true),
          Screen::Item.new(I18n.t("amortis_ui.form.expense_account"), view.expense_account, mono: true),
          Screen::Item.new(I18n.t("amortis_ui.assets.acquired_on"), fmt.date(view.acquired_on)),
          Screen::Item.new(I18n.t("amortis_ui.assets.in_service_on"),
            view.in_service_on.try { |day| fmt.date(day) } || I18n.t("amortis_ui.assets.not_in_service")),
          Screen::Item.new(I18n.t("amortis_ui.assets.gross_value"), fmt.amount(view.gross_value), mono: true),
          Screen::Item.new(I18n.t("amortis_ui.form.residual_value"), fmt.amount(view.residual_value), mono: true),
          Screen::Item.new(I18n.t("amortis_ui.form.plan"),
            [I18n.t(view.method_key), Ui.duration(view.life_months), view.rate.try { |rate| fmt.percent(rate) }].compact.reject(&.empty?).join(" · ")),
        ]
        if view.derogatory?
          items << Screen::Item.new(I18n.t("amortis_ui.form.fiscal"),
            [I18n.t(view.fiscal_method_key), Ui.duration(view.fiscal_life_months)].reject(&.empty?).join(" · "))
        end
        view.coefficient.try { |coefficient| items << Screen::Item.new(I18n.t("amortis_ui.assets.coefficient"), fmt.number(coefficient), Ui.url("coefficients"), mono: true) }
        items << Screen::Item.new(I18n.t("amortis_ui.assets.net_value_at", date: fmt.date(view.as_of)), fmt.amount(view.net_value), mono: true)
        items << Screen::Item.new(I18n.t("amortis_ui.assets.derogatory_cumul"), fmt.amount(view.derogatory_cumul), mono: true) if view.derogatory?
        view.parent_id.try { |parent| items << Screen::Item.new(I18n.t("amortis_ui.form.parent"), view.parent_code || "", Ui.url("asset", id: parent), mono: true) }
        view.entry_id.try { |entry| items << Screen::Item.new(I18n.t("amortis_ui.assets.acquisition_entry"), entry.to_s, Ui.entry_url(entry), mono: true) }
        items << Screen::Item.new(I18n.t("amortis_ui.form.card"), view.card_code, mono: true) unless view.card_code.empty?
        items << Screen::Item.new(I18n.t("amortis_ui.form.notes"), view.notes) unless view.notes.empty?
        items
      end

      private def components_table(view : Api::AssetView) : Table?
        return if view.component?
        rows = Api.components(actor, view.id).map do |item|
          url = Ui.url("asset", id: item.id)
          Table::Row.new([Table::Cell.new(item.code, url), Table::Cell.new(item.label, url), Present.money(fmt, item.gross_value),
                          Table::Cell.new("#{I18n.t(item.method_key)} #{Ui.duration(item.life_months)}".strip),
                          Present.money(fmt, item.net_value), Table::Cell.new(I18n.t(item.status_key))])
        end
        columns = [
          Table::Column.new("code", I18n.t("amortis_ui.assets.code"), "mono"),
          Table::Column.new("label", I18n.t("amortis_ui.assets.label")),
          Table::Column.new("gross", I18n.t("amortis_ui.assets.gross_value"), "number"),
          Table::Column.new("method", I18n.t("amortis_ui.assets.method")),
          Table::Column.new("net", I18n.t("amortis_ui.assets.net_value"), "number"),
          Table::Column.new("status", I18n.t("amortis_ui.assets.status")),
        ]
        table = Table.new(I18n.t("amortis_ui.components.title"), columns, rows, Ui.url("asset", id: view.id),
          empty_message: I18n.t("amortis_ui.components.none"), id: "amo-components")
        table.exportable = false
        table
      end

      private def impairments_table(view : Api::AssetView) : Table
        rows = Api.impairments(actor, view.id).map do |item|
          actions = [] of Screen::Action
          if can_write? && !item.posted?
            actions << post_action("amortis_ui.impairments.post", Ui.url("impairment_post", id: item.id), nil, "primary", "check")
            actions << post_action("amortis_ui.impairments.delete", Ui.url("impairment_delete", id: item.id),
              "amortis_ui.impairments.delete_confirm", "danger", "x")
          end
          Table::Row.new([Present.date(fmt, item.date), Present.money(fmt, item.amount), Table::Cell.new(item.label),
                          Table::Cell.new(I18n.t(item.posted? ? "amortis.posting_statuses.posted" : "amortis_ui.schedule.to_post")),
                          Table::Cell.new("", actions: actions)])
        end
        columns = [
          Table::Column.new("date", I18n.t("amortis_ui.impairments.date"), "mono"),
          Table::Column.new("amount", I18n.t("amortis_ui.impairments.amount"), "number"),
          Table::Column.new("label", I18n.t("amortis_ui.impairments.label")),
          Table::Column.new("state", I18n.t("amortis_ui.schedule.state")),
          Table::Column.new("actions", I18n.t("amortis_ui.candidates.actions"), "actions", sortable: false),
        ]
        table = Table.new(I18n.t("amortis_ui.impairments.title"), columns, rows, Ui.url("asset", id: view.id),
          empty_message: I18n.t("amortis_ui.impairments.none"), id: "amo-impairments")
        table.exportable = false
        table
      end

      private def impairment_form(view : Api::AssetView, errors : Hash(String, Array(String)),
                                  values : Hash(String, String)) : Form?
        return if !can_write? || view.disposed?
        form = Form.new([Form::Group.new(nil, [
          Form::Field.new("date", I18n.t("amortis_ui.impairments.date"), "date", values["date"]? || Partiduo::Api::Core.today.to_s("%F"), required: true),
          Form::Field.new("amount", I18n.t("amortis_ui.impairments.amount"), "number", values["amount"]? || "", required: true,
            mono: true, help: I18n.t("amortis_ui.impairments.amount_help")),
          Form::Field.new("label", I18n.t("amortis_ui.impairments.label"), value: values["label"]? || "", maxlength: 255),
        ])])
        errors.each { |name, messages| messages.each { |message| form.add_error(name, message) } } if values["form"]? == "impairment"
        form
      end

      private def disposal_facts(view : Api::AssetView, item : Api::DisposalView) : Array(Screen::Item)
        items = [
          Screen::Item.new(I18n.t("amortis_ui.disposal.kind"), I18n.t(item.kind_key)),
          Screen::Item.new(I18n.t("amortis_ui.disposal.date"), fmt.date(item.disposed_on)),
          Screen::Item.new(I18n.t("amortis_ui.disposal.price"), fmt.amount(item.price), mono: true),
          Screen::Item.new(I18n.t("amortis_ui.disposal.net_value"), fmt.amount(item.price - item.result), mono: true),
          Screen::Item.new(I18n.t(item.result >= 0 ? "amortis_ui.disposal.gain" : "amortis_ui.disposal.loss"), fmt.amount(item.result.abs), mono: true),
        ]
        if Api.settings(actor).regime == "fr"
          items << Screen::Item.new(I18n.t("amortis_ui.disposal.short_term"), fmt.amount(item.short_term), mono: true)
          items << Screen::Item.new(I18n.t("amortis_ui.disposal.long_term"), fmt.amount(item.long_term), mono: true)
        end
        items << Screen::Item.new(I18n.t("amortis_ui.disposal.state"),
          I18n.t(item.posted? ? "amortis.posting_statuses.posted" : "amortis_ui.schedule.to_post"))
        items
      end

      private def disposal_entry(view : Api::AssetView) : Table?
        item = view.disposal || return
        return if item.posted? || item.parent_disposal_id
        Present.entry_lines_table(Api.disposal_entry(actor, view.id), fmt, Ui.url("asset", id: view.id), "amo-disposal-entry")
      end

      private def disposal_actions(view : Api::AssetView) : Array(Screen::Action)?
        item = view.disposal || return
        return if !can_write? || item.posted? || item.parent_disposal_id
        [post_action("amortis_ui.disposal.post", Ui.url("dispose_post", id: view.id), "amortis_ui.disposal.post_confirm", "primary", "check"),
         post_action("amortis_ui.disposal.cancel", Ui.url("dispose_cancel", id: view.id), "amortis_ui.disposal.cancel_confirm", "", "x")]
      end

      private def dispose_form(view : Api::AssetView, errors : Hash(String, Array(String)), values : Hash(String, String)) : Form?
        return if !can_write? || view.disposed?
        form = Form.new([Form::Group.new(nil, [
          Form::Field.new("disposed_on", I18n.t("amortis_ui.disposal.date"), "date",
            values["disposed_on"]? || Partiduo::Api::Core.today.to_s("%F"), required: true),
          Form::Field.new("kind", I18n.t("amortis_ui.disposal.kind"), "select", values["kind"]? || "sale",
            options: code_options(Api::DISPOSAL_KINDS, "amortis.disposal_kinds")),
          Form::Field.new("price", I18n.t("amortis_ui.disposal.price"), "number", values["price"]? || "0", mono: true),
          Form::Field.new("label", I18n.t("amortis_ui.disposal.label"), value: values["label"]? || "", maxlength: 255),
        ])])
        errors.each { |name, messages| messages.each { |message| form.add_error(name, message) } } if values["form"]? == "dispose"
        form
      end

      private def postings_table(view : Api::AssetView) : Table
        rows = Api.postings(actor, asset_id: view.id).map do |item|
          Present.posting_row(item, fmt, can_write? && !item.cancelled?)
        end
        table = Table.new(I18n.t("amortis.menu.amortis_postings"), Present.posting_columns, rows, Ui.url("asset", id: view.id),
          empty_message: I18n.t("amortis_ui.postings.none"), id: "amo-asset-postings")
        table.exportable = false
        table
      end
    end

    # Enregistre une dépréciation ou une reprise (`Api.add_impairment`).
    class ImpairmentAddHandler < AssetDetailHandler
      def get
        go(Ui.url("asset", id: id_param))
      end

      def post
        values = {"form" => "impairment", "date" => field("date"), "amount" => field("amount"), "label" => field("label")}
        day = date_field("date")
        amount = decimal_field("amount")
        errors = {} of String => Array(String)
        errors["date"] = [I18n.t("ui.forms.invalid_date")] if day.nil?
        errors["amount"] = [I18n.t("ui.forms.invalid_number")] if amount.nil?
        return render_detail(id_param, errors, values, 422) if day.nil? || amount.nil?
        result = Api.add_impairment(actor, id_param, Api::ImpairmentInput.new(day, amount, field("label")))
        return render_detail(id_param, errors_of(result), values, 422) if result.failure?
        flash["success"] = I18n.t("amortis_ui.flash.impairment_added")
        go(Ui.url("asset", id: id_param))
      end
    end

    class ImpairmentPostHandler < Handler
      def get
        go(Ui.url("assets"))
      end

      def post
        asset_id = Api.impairment(actor, id_param).asset_id
        after(Api.post_impairment(actor, id_param), "amortis_ui.flash.posted", Ui.url("asset", id: asset_id))
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(Ui.url("assets"))
      end
    end

    class ImpairmentDeleteHandler < Handler
      def get
        go(Ui.url("assets"))
      end

      def post
        asset_id = Api.impairment(actor, id_param).asset_id
        after(Api.delete_impairment(actor, id_param), "amortis_ui.flash.deleted", Ui.url("asset", id: asset_id))
      end
    end

    # Enregistre une cession ou une mise au rebut (`Api.dispose`).
    class DisposeHandler < AssetDetailHandler
      def get
        go(Ui.url("asset", id: id_param))
      end

      def post
        values = {"form" => "dispose", "disposed_on" => field("disposed_on"), "kind" => field("kind"), "price" => field("price"),
                  "label" => field("label")}
        day = date_field("disposed_on")
        price = field("price").empty? ? BigDecimal.new(0) : decimal_field("price")
        errors = {} of String => Array(String)
        errors["disposed_on"] = [I18n.t("ui.forms.invalid_date")] if day.nil?
        errors["price"] = [I18n.t("ui.forms.invalid_number")] if price.nil?
        return render_detail(id_param, errors, values, 422) if day.nil? || price.nil?
        result = Api.dispose(actor, id_param, Api::DisposalInput.new(day, field("kind"), price, field("label")))
        return render_detail(id_param, errors_of(result), values, 422) if result.failure?
        flash["success"] = I18n.t("amortis_ui.flash.disposed")
        go(Ui.url("asset", id: id_param))
      end
    end

    class DisposeCancelHandler < Handler
      def get
        go(Ui.url("asset", id: id_param))
      end

      def post
        after(Api.cancel_disposal(actor, id_param), "amortis_ui.flash.disposal_cancelled", Ui.url("asset", id: id_param))
      end
    end

    class DisposePostHandler < Handler
      def get
        go(Ui.url("asset", id: id_param))
      end

      def post
        after(Api.post_disposal(actor, id_param), "amortis_ui.flash.posted", Ui.url("asset", id: id_param))
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(Ui.url("asset", id: id_param))
      end
    end
  end
end
