# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Calcul des plans d'amortissement (D-AMO-005, D-AMO-006) : fonction pure
  # d'une immobilisation et des exercices, sans base. Montants en
  # `BigDecimal`, arrondis au centime par exercice (arrondi commercial) ; la
  # dernière dotation solde le plan.
  #
  # * *Linéaire* : du jour de la mise en service, prorata temporis au jour
  #   (jours réels de l'exercice rapportés à sa durée, ou année commerciale
  #   de 360 jours) ; l'annuité est la base restante répartie sur la durée
  #   restante, ce qui fait repartir le plan de la valeur nette après une
  #   dépréciation.
  # * *Dégressif français* : du premier jour du mois d'acquisition,
  #   prorata en mois ; taux linéaire × coefficient (`Coefficients.fr`) ;
  #   passage au linéaire quand l'annuité linéaire sur la durée restante
  #   dépasse l'annuité dégressive.
  # * *Dégressif belge* : du jour de la mise en service, prorata temporis ;
  #   double du taux linéaire plafonné à 40 % ; passage au linéaire quand
  #   l'annuité linéaire sur la valeur d'origine dépasse la dégressive.
  # * *Plan fiscal* (France) : son mode et sa durée sur la valeur brute ;
  #   l'écart avec le plan comptable fait l'amortissement dérogatoire
  #   (dotation s'il est positif, reprise sinon).
  #
  # Interne.
  module Plan
    alias D = BigDecimal

    ZERO = BigDecimal.new(0)

    METHODS        = %w[linear degressive none]
    FISCAL_METHODS = %w[same linear degressive]
    DAY_COUNTS     = %w[actual 360]

    record Input,
      regime : String,
      day_count : String,
      acquired_on : Time,
      in_service_on : Time?,
      gross : D,
      residual : D,
      method : String,
      life_months : Int32,
      fiscal_method : String = "same",
      fiscal_life_months : Int32? = nil,
      impairments : Array({Time, D}) = [] of {Time, D},
      disposed_on : Time? = nil do
      # Plan fiscal distinct (France seulement) : source de dérogatoire.
      def derogatory? : Bool
        regime == "fr" && fiscal_method != "same" && method != "none"
      end
    end

    # Ligne d'un plan, pour un exercice : dotations et cumuls de clôture.
    record Row,
      exercise : Exercise,
      accounting : D,
      accounting_cumul : D,
      accounting_mode : String,
      impairment : D,
      impairment_cumul : D,
      fiscal : D,
      fiscal_cumul : D,
      fiscal_mode : String,
      derogatory : D,
      derogatory_cumul : D,
      net_value : D,
      disposed : Bool do
      def accounting_opening : D
        accounting_cumul - accounting
      end

      def fiscal_opening : D
        fiscal_cumul - fiscal
      end

      def derogatory_opening : D
        derogatory_cumul - derogatory
      end

      def impairment_opening : D
        impairment_cumul - impairment
      end
    end

    # Résultat d'une sortie : valeurs à la date de sortie, résultat
    # comptable, plus ou moins-value fiscale à court et à long terme.
    record DisposalResult,
      gross : D,
      accounting_cumul : D,
      impairment_cumul : D,
      derogatory_cumul : D,
      net_value : D,
      price : D,
      result : D,
      fiscal_net_value : D,
      short_term : D,
      long_term : D

    record Step, amount : D, mode : String

    # Premier et dernier jour que le plan peut toucher : bornes des
    # exercices à fournir à `rows`.
    def self.horizon(input : Input) : {Time, Time}
      start = month_start(input.acquired_on)
      months = Math.max(input.life_months, input.fiscal_life_months || 0)
      service = input.in_service_on || input.acquired_on
      finish = [service.shift(months: months), start.shift(months: months), input.acquired_on]
      dates = input.impairments.map(&.[0])
      finish.concat(dates)
      input.disposed_on.try { |day| finish << day }
      {start, finish.max}
    end

    def self.rows(input : Input, exercises : Array(Exercise)) : Array(Row)
      accounting = series(input, input.method, input.gross - input.residual, input.life_months, input.impairments, exercises)
      fiscal = if input.derogatory?
                 series(input, input.fiscal_method, input.gross, input.fiscal_life_months || input.life_months,
                   [] of {Time, D}, exercises)
               else
                 accounting
               end
      impairments = exercises.map { |exercise| impairment_in(input.impairments, exercise, input.disposed_on) }
      active = exercises.map_with_index do |exercise, index|
        moving = !accounting[index].amount.zero? || !fiscal[index].amount.zero? || !impairments[index].zero?
        moving || disposed_in?(input, exercise)
      end
      last = active.rindex(true)
      return [] of Row if last.nil?
      first = active.index(true) || last

      acc_cumul = fis_cumul = imp_cumul = der_cumul = ZERO
      rows = [] of Row
      exercises.each_with_index do |exercise, index|
        acc, fis, imp = accounting[index], fiscal[index], impairments[index]
        acc_cumul += acc.amount
        fis_cumul += fis.amount
        imp_cumul += imp
        derogatory = input.derogatory? ? fis.amount - acc.amount : ZERO
        der_cumul += derogatory
        next if index < first || index > last
        rows << Row.new(exercise: exercise, accounting: acc.amount, accounting_cumul: acc_cumul, accounting_mode: acc.mode,
          impairment: imp, impairment_cumul: imp_cumul, fiscal: fis.amount, fiscal_cumul: fis_cumul, fiscal_mode: fis.mode,
          derogatory: derogatory, derogatory_cumul: der_cumul, net_value: input.gross - acc_cumul - imp_cumul,
          disposed: disposed_in?(input, exercise))
      end
      rows
    end

    # Valeurs et plus ou moins-values d'une sortie au `disposed_on` de
    # `input`, au prix `price`, d'après les lignes du plan.
    def self.disposal(input : Input, rows : Array(Row), price : D) : DisposalResult
      day = input.disposed_on || raise ArgumentError.new("sortie sans date")
      upto = rows.select { |row| row.exercise.starts_on <= day }
      last = upto.last?
      acc = last.try(&.accounting_cumul) || ZERO
      imp = last.try(&.impairment_cumul) || ZERO
      der = last.try(&.derogatory_cumul) || ZERO
      fis = last.try(&.fiscal_cumul) || ZERO
      net = input.gross - acc - imp
      fiscal_net = input.gross - fis
      gain = price - fiscal_net
      held = day >= input.acquired_on.shift(years: 2)
      depreciable = input.method != "none"
      short_term, long_term = if !held
                                {gain, ZERO}
                              elsif depreciable && gain >= 0
                                short = gain < fis ? gain : fis
                                {short, gain - short}
                              elsif depreciable
                                {gain, ZERO}
                              else
                                {ZERO, gain}
                              end
      DisposalResult.new(gross: input.gross, accounting_cumul: acc, impairment_cumul: imp, derogatory_cumul: der,
        net_value: net, price: price, result: price - net, fiscal_net_value: fiscal_net, short_term: short_term,
        long_term: long_term)
    end

    # --- Séries -------------------------------------------------------------------

    private def self.series(input : Input, method : String, base : D, months : Int32, impairments : Array({Time, D}),
                            exercises : Array(Exercise)) : Array(Step)
      none = exercises.map { Step.new(ZERO, "") }
      service = input.in_service_on
      return none if service.nil? || method == "none" || months <= 0 || base <= 0
      if method == "degressive" && input.regime == "fr"
        coefficient = Coefficients.fr(input.acquired_on, months) || return linear(input, base, months, service, impairments, exercises)
        french_degressive(input, base, months, coefficient, impairments, exercises)
      elsif method == "degressive"
        belgian_degressive(input, base, months, service, impairments, exercises)
      else
        linear(input, base, months, service, impairments, exercises)
      end
    end

    private def self.linear(input : Input, base : D, months : Int32, start : Time, impairments : Array({Time, D}),
                            exercises : Array(Exercise)) : Array(Step)
      finish = start.shift(months: months) - 1.day
      stop = stop_day(input, finish)
      life = BigDecimal.new(months) / 12
      elapsed = cumul = imp = ZERO
      exercises.map do |exercise|
        step = Step.new(ZERO, "")
        if exercise.ends_on >= start && exercise.starts_on <= stop
          from = max(exercise.starts_on, start)
          to = min(exercise.ends_on, stop)
          remaining = base - cumul - imp
          left = life - elapsed
          part = fraction(input.day_count, from, to, exercise)
          if remaining > 0
            amount = to == finish || left <= part ? remaining : money(remaining * part / left)
            amount = remaining if amount > remaining
            cumul += amount
            step = Step.new(amount, "linear")
          end
          elapsed += fraction(input.day_count, from, min(exercise.ends_on, finish), exercise)
        end
        imp += impairment_in(impairments, exercise, input.disposed_on)
        step
      end
    end

    private def self.french_degressive(input : Input, base : D, months : Int32, coefficient : D,
                                       impairments : Array({Time, D}), exercises : Array(Exercise)) : Array(Step)
      start = month_start(input.acquired_on)
      finish = start.shift(months: months) - 1.day
      stop = stop_day(input, finish)
      rate = coefficient * 12 / months
      cumul = imp = ZERO
      switched = false
      exercises.map do |exercise|
        step = Step.new(ZERO, "")
        if exercise.ends_on >= start && exercise.starts_on <= stop
          from = max(exercise.starts_on, start)
          to = min(exercise.ends_on, stop)
          remaining = base - cumul - imp
          if remaining > 0
            part = fraction("360", from, to, exercise)
            left = fraction("360", from, finish, exercise)
            degressive = remaining * rate * part
            straight = left > 0 ? remaining * part / left : remaining
            switched ||= straight > degressive
            amount = to == finish ? remaining : money(switched ? straight : degressive)
            amount = remaining if amount > remaining
            cumul += amount
            step = Step.new(amount, switched ? "linear" : "degressive")
          end
        end
        imp += impairment_in(impairments, exercise, input.disposed_on)
        step
      end
    end

    private def self.belgian_degressive(input : Input, base : D, months : Int32, start : Time,
                                        impairments : Array({Time, D}), exercises : Array(Exercise)) : Array(Step)
      finish = start.shift(months: months) - 1.day
      stop = stop_day(input, finish)
      rate = Coefficients.be_rate(months)
      annual = base * 12 / months
      cumul = imp = ZERO
      switched = false
      exercises.map do |exercise|
        step = Step.new(ZERO, "")
        if exercise.ends_on >= start && exercise.starts_on <= stop
          to = min(exercise.ends_on, stop)
          remaining = base - cumul - imp
          if remaining > 0
            part = fraction(input.day_count, max(exercise.starts_on, start), to, exercise)
            degressive = remaining * rate * part
            straight = annual * part
            switched ||= straight > degressive
            amount = to == finish ? remaining : money(switched ? straight : degressive)
            amount = remaining if amount > remaining
            cumul += amount
            step = Step.new(amount, switched ? "linear" : "degressive")
          end
        end
        imp += impairment_in(impairments, exercise, input.disposed_on)
        step
      end
    end

    # --- Outils -------------------------------------------------------------------

    # Part d'année de `from` à `to` (compris) dans `exercise` : jours réels
    # rapportés à l'exercice (`actual`), ou jours de l'année commerciale de
    # 360 jours (`360`, mois de 30 jours).
    def self.fraction(day_count : String, from : Time, to : Time, exercise : Exercise) : D
      return ZERO if to < from
      if day_count == "360"
        BigDecimal.new(days360(from, to + 1.day)) / 360
      else
        BigDecimal.new((to - from).days + 1) * exercise.years / exercise.days
      end
    end

    # Jours entre deux dates (fin exclue) en mois de 30 jours (30E/360).
    def self.days360(from : Time, limit : Time) : Int32
      first = Math.min(from.day, 30)
      last = Math.min(limit.day, 30)
      (limit.year - from.year) * 360 + (limit.month - from.month) * 30 + (last - first)
    end

    def self.money(value : D) : D
      value.round(2, mode: :ties_away)
    end

    def self.month_start(day : Time) : Time
      Time.utc(day.year, day.month, 1)
    end

    private def self.disposed_in?(input : Input, exercise : Exercise) : Bool
      day = input.disposed_on
      !day.nil? && exercise.includes?(day)
    end

    private def self.stop_day(input : Input, finish : Time) : Time
      disposed = input.disposed_on
      disposed && disposed < finish ? disposed : finish
    end

    private def self.impairment_in(impairments : Array({Time, D}), exercise : Exercise, disposed_on : Time?) : D
      impairments.select { |(day, _)| exercise.includes?(day) && (disposed_on.nil? || day <= disposed_on) }.sum(ZERO, &.[1])
    end

    private def self.max(left : Time, right : Time) : Time
      left > right ? left : right
    end

    private def self.min(left : Time, right : Time) : Time
      left < right ? left : right
    end
  end
end
