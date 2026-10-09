# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Ui
    # Base des écrans de l'extension, sur celle des écrans du référentiel de
    # l'interface (listes, formulaires des gabarits `ui/reference/*.html`) :
    # fil d'Ariane « Immobilisations › … », listes de choix, lecture des
    # champs. L'accès a déjà été contrôlé par `PartiduoUi::ExtensionHandler`
    # à partir du montage ; `Amortis::Api` vérifie encore la permission de
    # chaque commande.
    abstract class Handler < PartiduoUi::ReferenceHandler
      alias Api = Amortis::Api
      alias Acc = Partiduo::Api::Accounting
      alias Form = PartiduoUi::Form
      alias Screen = PartiduoUi::Screen

      def actor : Partiduo::Api::Actor
        current.actor
      end

      def crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("amortis.menu.amortis", Ui.url("assets"))]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def settings_crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("core.menu.settings")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def can_write? : Bool
        can?(Api::WRITE)
      end

      def can_admin? : Bool
        can?(Api::ADMIN)
      end

      # --- Lecture des champs ---------------------------------------------------------

      def id_field(name : String) : Int64?
        field(name).to_i64?
      end

      def decimal_field(name : String) : BigDecimal?
        text = field(name)
        text.empty? ? nil : fmt.parse_decimal(text)
      end

      def date_field(name : String) : Time?
        fmt.parse_date(field(name))
      end

      # Durée saisie en années (décimales admises) ; en mois.
      def months_field(name : String) : Int32?
        years = decimal_field(name) || return
        (years * 12).round(0, mode: :ties_away).to_i
      end

      def years_value(months : Int32?) : String
        return "" if months.nil? || months <= 0
        fmt.input_number(BigDecimal.new(months) / 12, 2)
      end

      # --- Listes de choix -------------------------------------------------------------

      def blank_option(label_key : String = "amortis_ui.forms.none") : Form::Option
        option("", I18n.t(label_key))
      end

      def code_options(codes : Array(String), scope : String) : Array(Form::Option)
        codes.map { |code| option(code, I18n.t("#{scope}.#{code}")) }
      end

      # Journaux d'opérations diverses ouverts à l'acteur.
      def ledger_options : Array(Form::Option)
        Acc.ledgers(actor, Acc::LedgerKind::Misc, enabled_only: true).map do |ledger|
          option(ledger.id.to_s, "#{ledger.code} · #{ledger.name}")
        end
      rescue Partiduo::Api::AccessDenied
        [] of Form::Option
      end

      @exercises : Array(Api::ExerciseView)?

      def exercises : Array(Api::ExerciseView)
        @exercises ||= Api.exercises(actor)
      end

      # Exercice choisi (`year`), sinon celui qui contient la date du jour,
      # sinon le plus récent.
      def chosen_exercise : Api::ExerciseView?
        today = Partiduo::Api::Core.today
        query("year").to_i64?.try { |id| exercises.find(&.fiscal_year_id.==(id)) } ||
          exercises.find { |item| item.starts_on <= today <= item.ends_on } || exercises.first?
      end

      def exercise_options : Array(Form::Option)
        exercises.map { |item| option(item.fiscal_year_id.to_s, item.label) }
      end

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      # Redirection après une commande, avec le message du résultat.
      def after(result, success_key : String, url : String, params = {} of String => String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key, params)
        else
          flash["danger"] = messages(result)
        end
        go(url)
      end
    end

    # `/ext/AMORTIS/` : le registre.
    class IndexHandler < Handler
      def get
        go(Ui.url("assets"))
      end
    end
  end
end
