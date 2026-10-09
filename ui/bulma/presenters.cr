# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Ui
    alias Table = PartiduoUi::Table

    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten, B-EINV-001 du cœur).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)

      def initialize(values : Hash(String, String) | Hash(String, String?))
        @values = values.transform_values(&.as(String?))
      end

      def resolve_template_attribute(key : String)
        values[key]?
      end
    end

    def self.row(values : Hash(String, String) | Hash(String, String?)) : Row
      Row.new(values)
    end

    # Option d'une liste de choix d'un gabarit.
    def self.choice(value : String, label : String, selected : Bool) : Row
      row({"value" => value, "label" => label, "selected" => flag(selected)})
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("amortis:#{name}", **params)
    end

    def self.flag(value : Bool) : String?
      value ? "1" : nil
    end

    def self.entry_url(id : Int64) : String
      Marten.routes.reverse("accounting:entry", id: id)
    end

    # Durée lisible : en années (`5 ans`) si elle en compte un nombre
    # entier, sinon en mois (`30 mois`).
    def self.duration(months : Int32?) : String
      return "" if months.nil? || months <= 0
      months % 12 == 0 ? I18n.t("amortis_ui.duration.years", count: months // 12) : I18n.t("amortis_ui.duration.months", count: months)
    end

    # Classe Bulma de l'état d'une immobilisation.
    def self.status_class(status : String) : String
      case status
      when "in_service"  then "is-success"
      when "depreciated" then "is-info"
      when "disposed"    then "is-light"
      else                    "is-warning"
      end
    end

    # Présentation des vues du contrat (interne à l'interface).
    module Present
      alias Api = Amortis::Api

      def self.money(fmt : PartiduoUi::Format, value : BigDecimal) : Table::Cell
        Table::Cell.new(fmt.amount(value), sort: value, csv: fmt.csv_amount(value))
      end

      def self.date(fmt : PartiduoUi::Format, value : Time?) : Table::Cell
        Table::Cell.new(fmt.date(value), sort: value.try(&.to_s("%Y-%m-%d")) || "")
      end

      def self.mode(code : String) : String
        code.empty? ? "" : I18n.t("amortis.methods.#{code}")
      end

      # Tableau d'amortissement (fiche, aperçu de la saisie, export).
      def self.schedule_table(rows : Array(Api::ScheduleRowView), derogatory : Bool, fmt : PartiduoUi::Format, path : String,
                              posted : Bool = true, id : String = "amo-schedule") : Table
        columns = [
          Table::Column.new("exercise", I18n.t("amortis_ui.schedule.exercise"), "mono"),
          Table::Column.new("opening", I18n.t("amortis_ui.schedule.opening"), "number", secondary: true),
          Table::Column.new("charge", I18n.t("amortis_ui.schedule.charge"), "number"),
          Table::Column.new("cumul", I18n.t("amortis_ui.schedule.cumul"), "number"),
          Table::Column.new("impairment", I18n.t("amortis_ui.schedule.impairment"), "number", secondary: true),
          Table::Column.new("net", I18n.t("amortis_ui.schedule.net"), "number"),
          Table::Column.new("mode", I18n.t("amortis_ui.schedule.mode"), secondary: true),
        ]
        if derogatory
          columns << Table::Column.new("fiscal", I18n.t("amortis_ui.schedule.fiscal"), "number")
          columns << Table::Column.new("derogatory", I18n.t("amortis_ui.schedule.derogatory"), "number")
          columns << Table::Column.new("derogatory_cumul", I18n.t("amortis_ui.schedule.derogatory_cumul"), "number", secondary: true)
        end
        columns << Table::Column.new("state", I18n.t("amortis_ui.schedule.state")) if posted
        table_rows = rows.map do |row|
          cells = [
            Table::Cell.new(row.exercise.label, sort: row.exercise.starts_on.to_s("%Y-%m-%d")),
            money(fmt, row.accounting_opening), money(fmt, row.accounting), money(fmt, row.accounting_cumul),
            money(fmt, row.impairment), money(fmt, row.net_value), Table::Cell.new(mode(row.accounting_mode)),
          ]
          if derogatory
            cells << money(fmt, row.fiscal) << money(fmt, row.derogatory) << money(fmt, row.derogatory_cumul)
          end
          if posted
            state = if row.disposed
                      I18n.t("amortis_ui.schedule.disposed")
                    elsif row.posted?
                      I18n.t("amortis_ui.schedule.posted")
                    elsif !row.posted_depreciation.zero? || !row.posted_derogatory.zero?
                      I18n.t("amortis_ui.schedule.partly_posted")
                    else
                      I18n.t("amortis_ui.schedule.to_post")
                    end
            cells << Table::Cell.new(state)
          end
          Table::Row.new(cells, row.disposed ? "amo-disposed" : "")
        end
        table = Table.new(I18n.t("amortis_ui.schedule.title"), columns, table_rows, path,
          empty_message: I18n.t("amortis_ui.schedule.none"), id: id)
        table.pdf = true
        table
      end

      def self.entry_lines_table(lines : Array(Api::EntryLineView), fmt : PartiduoUi::Format, path : String,
                                 id : String) : Table
        columns = [
          Table::Column.new("account", I18n.t("amortis_ui.entry.account"), "mono", sortable: false),
          Table::Column.new("label", I18n.t("amortis_ui.entry.label"), sortable: false),
          Table::Column.new("debit", I18n.t("amortis_ui.entry.debit"), "number", sortable: false),
          Table::Column.new("credit", I18n.t("amortis_ui.entry.credit"), "number", sortable: false),
        ]
        rows = lines.map do |line|
          debit = line.side.debit? ? fmt.amount(line.amount) : ""
          credit = line.side.credit? ? fmt.amount(line.amount) : ""
          Table::Row.new([Table::Cell.new(line.account), Table::Cell.new(line.label), Table::Cell.new(debit),
                          Table::Cell.new(credit)])
        end
        table = Table.new(I18n.t("amortis_ui.entry.title"), columns, rows, path, empty_message: I18n.t("amortis_ui.entry.none"), id: id)
        table.exportable = false
        table
      end
    end
  end
end
