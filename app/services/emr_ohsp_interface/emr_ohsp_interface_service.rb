require 'emr_ohsp_interface/version'

module EmrOhspInterface
  module EmrOhspInterfaceService
    class << self
      require 'csv'
      require 'rest-client'
      require 'json'
      include EmrOhspInterface::Utils

      def settings
        file = File.read(Rails.root.join('db', 'idsr_metadata', 'idsr_ohsp_settings.json'))
        config = JSON.parse(file)
      end

      def server_config
        config =YAML.load_file("#{Rails.root}/config/application.yml")
      end

      def get_ohsp_facility_id
        file = File.open(Rails.root.join('db', 'idsr_metadata', 'emr_ohsp_facility_map.csv'))
        data = CSV.parse(file, headers: true)
        emr_facility_id = Location.current_health_center.id
        facility = data.select { |row| row['EMR_Facility_ID'].to_i == emr_facility_id }
        ohsp_id = facility[0]['OrgUnit ID']
      end

      def get_ohsp_de_ids(de, type)
        # this method returns an array ohsp report line ids
        result = []
        # ["waoQ016uOz1", "r1AT49VBKqg", "FPN4D0s6K3m", "zE8k2BtValu"]
        #  ds,              de_id     ,  <5yrs       ,  >=5yrs
        puts de
        if type == 'weekly'
        file = File.open(Rails.root.join('db', 'idsr_metadata', 'idsr_weekly_ohsp_ids.csv'))
        else
        file = File.open(Rails.root.join('db', 'idsr_metadata', 'idsr_monthly_ohsp_ids.csv'))
        end
        data = CSV.parse(file, headers: true)
        row = data.select { |row| row['Data Element Name'].strip.downcase.eql?(de.downcase.strip) }
        ohsp_ds_id = row[0]['Data Set ID']
        result << ohsp_ds_id
        ohsp_de_id = row[0]['UID']
        result << ohsp_de_id
        option1 = row[0]['<5Yrs']
        result << option1
        option2 = row[0]['>=5Yrs']
        result << option2

        return result
      end

      def get_data_set_id(type)
        if type == 'weekly'
          file = File.open(Rails.root.join('db', 'idsr_metadata', 'idsr_weekly_ohsp_ids.csv'))
        else
          file = File.open(Rails.root.join('db', 'idsr_metadata', 'idsr_monthly_ohsp_ids.csv'))
        end
        data = CSV.parse(file, headers: true)
        data_set_id = data.first['Data Set ID']
      end

      def generate_weekly_idsr_report(request=nil, start_date=nil, end_date=nil)

        diag_map = settings['weekly_idsr_map']
        site_id = Location.current.location_id

        epi_week = weeks_generator.last.first.strip
        start_date = weeks_generator.last.last.split('to')[0].strip if start_date.nil?
        end_date = weeks_generator.last.last.split('to')[1].strip if end_date.nil?

        # pull the data
        type = EncounterType.find_by_name 'Outpatient diagnosis'
        collection = {}

        diag_map.each do |key, value|
          options = {'<5yrs'=>nil, '>=5yrs'=>nil}
          concept_ids = ConceptName.where(name: value).collect { |cn| cn.concept_id }

          data = Encounter.where('encounter_datetime BETWEEN ? AND ?
          AND encounter_type = ? AND value_coded IN (?)
          AND concept_id IN(6543, 6542) AND encounter.site_id = ?',
                                 start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                 end_date.to_date.strftime('%Y-%m-%d 23:59:59'), type.id, concept_ids, site_id)
                          .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
          INNER JOIN person p ON p.person_id = encounter.patient_id')
                          .select('encounter.encounter_type, obs.value_coded, p.*')

          # under_five
          under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }
                           .collect { |record| record.person_id }
          options['<5yrs'] = under_five
          # above 5 years
          over_five = data.select { |record| calculate_age(record['birthdate']) >=5 }
                          .collect { |record| record.person_id }

          options['>=5yrs'] = over_five

          collection[key] = options
        end
          response = send_data(collection, 'weekly') if request == nil
          
        return collection
      end

      def generate_quarterly_idsr_report(request=nil, start_date=nil, end_date=nil)
        epi_month = quarters_generator.first.first.strip
        start_date = quarters_generator.first.last[1].split('to').first.strip if start_date.nil?
        end_date = quarters_generator.first.last[1].split('to').last.strip if end_date.nil?
        indicators = [
          'Diabetes Mellitus',
          'Cervical Cancer',
          'Hypertension',
          'Onchocerciasis',
          'Trachoma',
          'Lymphatic Filariasis',
          'Tuberculosis',
          'Trypanosomiasis',
          'Epilepsy',
          'Depression',
          'Suicide',
          'Psychosis'
        ]

        diagnosis_concepts = ['Primary Diagnosis', 'Secondary Diagnosis']
        encounters = ['OUTPATIENT DIAGNOSIS', 'ADMISSION DIAGNOSIS']

        report_struct = indicators.each_with_object({}) do |indicator, report|
          report[indicator] = ['<5 yrs', '>=5 yrs'].each_with_object({}) do |group, sub_report|
            sub_report[group] = {
              outpatient_cases: [],
              inpatient_cases: [],
              inpatient_cases_death: [],
              tested_malaria: [],
              tested_positive_malaria: []
            }
          end
        end

        admitted_patient_died = proc do |patient|
          visit_type = patient['visit_type']
          dead = patient['dead']

          visit_type == 'ADMISSION DIAGNOSIS' && dead
        end


        diagonised = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT
            e.patient_id,
            p.birthdate,
            d.name diagnosis,
            et.name visit_type
          FROM
            encounter e
          INNER JOIN
            obs ON obs.encounter_id = e.encounter_id
          INNER JOIN
            person p ON p.person_id = e.patient_id
          INNER JOIN concept_name d ON d.concept_id = obs.value_coded
          INNER JOIN 
            encounter_type et ON et.encounter_type_id = e.encounter_type
          WHERE
            e.encounter_type IN (#{EncounterType.where(name: encounters).pluck(:encounter_type_id).join(',')})
            AND DATE(e.encounter_datetime) > '#{start_date}'
            AND DATE(e.encounter_datetime) < '#{end_date}'
            AND obs.concept_id IN (#{ConceptName.where(name: diagnosis_concepts).pluck(:concept_id).join(',')})
            AND obs.value_coded IN (#{ConceptName.where(name: indicators).pluck(:concept_id).join(',')})
            AND e.site_id = #{Location.current.location_id}
          GROUP BY
            p.person_id
        SQL

        malaria_tests = lab_results(test_types: ['Malaria Screening'], start_date: start_date, end_date: end_date)

        tested_patient_ids = malaria_tests.map { |patient| patient['patient_id'] }

        tested_positive = lambda do |patient|
          patient_id = patient['patient_id']
          return false unless tested_patient_ids.include?(patient_id)
          
          results = malaria_tests.find { |test| test['patient_id'] == patient_id }['results']
          ['positive', 'parasites seen'].include?(results)
        end
          diagonised.each do |patient|
            diagnosis = patient['diagnosis'].titleize
            visit_type = patient['visit_type']
            patient_id = patient['patient_id']
            birthdate = patient['birthdate']

            five_plus = '>=5 yrs'
            less_than_5 = '<5 yrs'

            age_group = birthdate > 5.years.ago ? less_than_5 : five_plus
          
            report_struct[diagnosis][age_group][:outpatient_cases] << patient_id if visit_type == 'OUTPATIENT DIAGNOSIS'
            report_struct[diagnosis][age_group][:inpatient_cases] << patient_id if visit_type == 'ADMISSION DIAGNOSIS'
            if tested_patient_ids.include?(patient_id)
              report_struct[diagnosis][age_group][:tested_malaria] << patient_id
            end
            report_struct[diagnosis][age_group][:tested_positive_malaria] << patient_id if tested_positive.call(patient)
            if admitted_patient_died.call(patient)
              report_struct[diagnosis][age_group][:inpatient_cases_death] << patient_id
            end
          end
        report_struct
      end

      # idsr monthly report
      def generate_monthly_idsr_report(request=nil, start_date=nil, end_date=nil)
        diag_map = settings['monthly_idsr_map']
        epi_month = months_generator.first.first.strip
        start_date = months_generator.first.last[1].split('to').first.strip if start_date.nil?
        end_date = months_generator.first.last[1].split('to').last.strip if end_date.nil?
        type = EncounterType.find_by_name 'Outpatient diagnosis'
        collection = {}

        special_indicators = ['Malaria in Pregnancy',
                              'HIV New Initiated on ART',
                              'Diarrhoea In Under 5',
                              'Malnutrition In Under 5',
                              'Underweight Newborns < 2500g in Under 5 Cases',
                              'Severe Pneumonia in under 5 cases']

        diag_map.each do |key, value|
          options = {'<5yrs'=>nil, '>=5yrs'=>nil}
          concept_ids = ConceptName.where(name: value).collect { |cn| cn.concept_id }
          if !special_indicators.include?(key)
              data = Encounter.where('encounter_datetime BETWEEN ? AND ?
              AND encounter_type = ? AND value_coded IN (?)
              AND concept_id IN(6543, 6542) AND encounter.site_id = ?',
                                     start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                     end_date.to_date.strftime('%Y-%m-%d 23:59:59'), type.id, concept_ids,
                                     Location.current.location_id)
                              .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
              INNER JOIN person p ON p.person_id = encounter.patient_id')
                              .select('encounter.encounter_type, obs.value_coded, p.*')

              # under_five
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record.person_id }.uniq
              options['<5yrs'] = under_five
              # above 5 years
              over_five = data.select { |record| calculate_age(record['birthdate']) >=5 }\
                              .collect { |record| record.person_id }.uniq

              options['>=5yrs'] = over_five

              collection[key] = options
          else
            if key.eql?('Malaria in Pregnancy')
              mal_patient_id = Encounter.where('encounter_datetime BETWEEN ? AND ?
              AND encounter_type = ? AND value_coded IN (?)
              AND concept_id IN(6543, 6542) AND encounter.site_id = ?',
                                               start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                               end_date.to_date.strftime('%Y-%m-%d 23:59:59'), type.id, concept_ids,
                                               Location.current.location_id)
                                        .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
              INNER JOIN person p ON p.person_id = encounter.patient_id')\
                                        .select('encounter.encounter_type, obs.value_coded, p.*')

              mal_patient_id=   mal_patient_id.collect { |record| record.person_id }
              # find those that are pregnant
              preg = Observation.where(["concept_id = 6131 AND obs_datetime
                                         BETWEEN ? AND ? AND person_id IN(?)
                                          AND value_coded =1065",
                                        start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                        end_date.to_date.strftime('%Y-%m-%d 23:59:59'), mal_patient_id ])

               options['>=5yrs'] = preg.collect { |record| record.person_id } rescue 0
               collection[key] = options
            end

            if key.eql?('HIV New Initiated on ART')
             data = ActiveRecord::Base.connection.select_all(
                        "SELECT * FROM temp_earliest_start_date
                            WHERE date_enrolled BETWEEN '#{start_date}' AND '#{end_date}'
                            AND date_enrolled = earliest_start_date
                            AND site_id = #{Location.current.location_id}
                             GROUP BY patient_id" ).to_a

              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record['patient_id'] }

              over_five = data.select { |record| calculate_age(record['birthdate']) >=5 }\
                              .collect { |record| record['patient_id'] }

              options['<5yrs'] = under_five
              options['>=5yrs'] = over_five

              collection[key] = options
            end

            if key.eql?('Diarrhoea In Under 5')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                        end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                        type.id,
                                        concept_ids)

              # under_five
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record.person_id }
              options['<5yrs'] = under_five
              collection[key] = options
            end


            if key.eql?('Malnutrition In Under 5')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                        end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                        type.id,
                                        concept_ids)

              # under_five
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record.person_id }
              options['<5yrs'] = under_five
              collection[key] = options
            end


            if key.eql?('Underweight Newborns < 2500g in Under 5 Cases')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                        end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                        type.id,
                                        concept_ids)

              # under_five
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record.person_id }
              options['<5yrs'] = under_five
              collection[key] = options
            end

            if key.eql?('Severe Pneumonia in under 5 cases')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                        end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                        type.id,
                                        concept_ids)

              # under_five
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record.person_id }
              options['<5yrs'] = under_five
              collection[key] = options
            end
          end
        end
          response = send_data(collection, 'monthly') if request == nil
        return collection
      end

      def fetch_encounter_data(start_date, end_date, type_id, concept_ids)
        Encounter.where('encounter_datetime BETWEEN ? AND ? 
                        AND encounter_type = ? 
                        AND value_coded IN (?)
                        AND concept_id IN(6543, 6542) 
                        AND encounter.site_id = ?',
                        start_date, end_date, type_id, concept_ids, Location.current.location_id)
                  .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
                          INNER JOIN person p ON p.person_id = encounter.patient_id')
                  .select('encounter.encounter_type, obs.value_coded, p.*')
      end

      def generate_hmis_15_report(start_date=nil, end_date=nil)

        diag_map = settings['hmis_15_map']
    
        # pull the data
        type = EncounterType.find_by_name 'Outpatient diagnosis'
        collection = {}
    
        special_indicators = ['Malaria - new cases (under 5)',
                              'Malaria - new cases (5 & over)',
                              'HIV confirmed positive (15-49 years) new cases',
                              'Diarrhoea non - bloody -new cases (under5)',
                              'Malnutrition - new case (under 5)',
                              'Acute respiratory infections - new cases (U5)']
    
        diag_map.each do |key, value|
          options = {'ids'=>nil}
          concept_ids = ConceptName.where(name: value).collect { |cn| cn.concept_id }
    
          if !special_indicators.include?(key)
            data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                        end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                        type.id,
                                        concept_ids)
              
            all = data.collect { |record| record.person_id }
    
    
            options['ids'] = all
    
            collection[key] = options
          else
            if key.eql?('Malaria - new cases (under 5)')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                          end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                          type.id,
                                          concept_ids)
    
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record['person_id'] }
    
              options['ids'] = under_five
    
              collection[key] = options
            end
    
            if key.eql?('Malaria - new cases (5 & over)')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                          end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                          type.id,
                                          concept_ids)
    
              over_and_five = data.select { |record| calculate_age(record['birthdate']) >= 5 }\
                                  .collect { |record| record['person_id'] }
    
              options['ids'] = over_and_five
    
              collection[key] = options
            end
    
            if key.eql?('HIV confirmed positive (15-49 years) new cases')
              data = ActiveRecord::Base.connection.select_all(
                "SELECT * FROM temp_earliest_start_date
                  WHERE date_enrolled BETWEEN '#{start_date}' AND '#{end_date}'
                  AND date_enrolled = earliest_start_date
                  AND site_id = #{Location.current.location_id}
                  GROUP BY patient_id" ).to_a
    
              over_and_15_49 = data.select { |record| calculate_age(record['birthdate']) >= 15 && calculate_age(record['birthdate']) <=49 }\
                                   .collect { |record| record['patient_id'] }
    
              options['ids'] = over_and_15_49
    
              collection[key] = options
            end

            if key.eql?('Diarrhoea non - bloody -new cases (under5)')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                          end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                          type.id,
                                          concept_ids)
    
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record['person_id'] }
    
              options['ids'] = under_five

              collection[key] = options
            end

            if key.eql?('Malnutrition - new case (under 5)')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                          end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                          type.id,
                                          concept_ids)
    
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record['person_id'] }
    
              options['ids'] = under_five

              collection[key] = options
            end

            if key.eql?('Acute respiratory infections - new cases (U5)')
              data = fetch_encounter_data(start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                          end_date.to_date.strftime('%Y-%m-%d 23:59:59'),
                                          type.id,
                                          concept_ids)
              under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                               .collect { |record| record['person_id'] }
    
              options['ids'] = under_five

              collection[key] = options
            end

        end
        end
         collection
      end

      def disaggregate(disaggregate_key, concept_ids, start_date, end_date, type)
        options = {'ids'=>nil}
        data = Encounter.where('encounter_datetime BETWEEN ? AND ?
        AND encounter_type = ? AND value_coded IN (?)
        AND concept_id IN(6543, 6542)',
                               start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                               end_date.to_date.strftime('%Y-%m-%d 23:59:59'), type.id, concept_ids)\
                        .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
        INNER JOIN person p ON p.person_id = encounter.patient_id')\
                        .select('encounter.encounter_type, obs.value_coded, p.*')

        if disaggregate_key == 'less'
        options['ids'] = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                             .collect { |record| record['person_id'] }
        else 
          if disaggregate_key == 'greater'
            options['ids'] = data.select { |record| calculate_age(record['birthdate']) >= 5 }\
                                 .collect { |record| record['person_id'] }
          end
        end

        options
      end

      def generate_hmis_17_report(start_date=nil, end_date=nil)

        diag_map = settings['hmis_17_map']
    
        # pull the data
        type = EncounterType.find_by_name 'Outpatient diagnosis'
        collection = {}
    
        special_indicators = [
          'Referals from other institutions',
          'OPD total attendance',
          'Referal to other institutions',
          'Malaria 5 years and older - new',
          'HIV/AIDS - new'
        ]

        special_under_five_indicators = [
          'Measles under five years - new',
          'Pneumonia under 5 years- new',
          'Dysentery under 5 years - new',
          'Diarrhoea non - bloody -new cases (under5)',
          'Malaria under 5 years - new'
        ]

        diag_map.each do |key, value|
          options = {'ids'=>nil}
          concept_ids = ConceptName.where(name: value).collect { |cn| cn.concept_id }
    
          if !special_indicators.include?(key) && !special_under_five_indicators.include?(key)
            data = Encounter.where('encounter_datetime BETWEEN ? AND ?
            AND encounter_type = ? AND value_coded IN (?)
            AND concept_id IN(6543, 6542)',
                                   start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                   end_date.to_date.strftime('%Y-%m-%d 23:59:59'), type.id, concept_ids)\
                            .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
            INNER JOIN person p ON p.person_id = encounter.patient_id')\
                            .select('encounter.encounter_type, obs.value_coded, p.*')
    
            all = data.collect { |record| record.person_id }
    
    
            options['ids'] = all
    
            collection[key] = options
          else
            if key.eql?('Referals from other institutions') 
              _type = EncounterType.find_by_name 'PATIENT REGISTRATION'
              visit_type = ConceptName.find_by_name 'Type of visit'
      
              data = Encounter.where('encounter_datetime BETWEEN ? AND ?
              AND encounter_type = ? AND value_coded IS NOT NULL
              AND obs.concept_id = ?', start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                     end_date.to_date.strftime('%Y-%m-%d 23:59:59'), _type.id, visit_type.concept_id)\
                              .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
              INNER JOIN person p ON p.person_id = encounter.patient_id
              INNER JOIN concept_name c ON c.concept_id = 6541')\
                              .select('encounter.encounter_type, obs.value_coded, obs.obs_datetime, p.*, c.name visit_type')\
                              .group('p.person_id, encounter.encounter_id')

              all = data.collect { |record| record.person_id }
    
              options['ids'] = all
      
              collection[key] = options
            end

            if key.eql?('OPD total attendance')
              programID = Program.find_by_name 'OPD Program'
              data = Encounter.find_by_sql(
                "SELECT patient_id, DATE_FORMAT(encounter_datetime,'%Y-%m-%d') enc_date
                FROM encounter e
                LEFT OUTER JOIN person p ON p.person_id = e.patient_id
                WHERE e.voided = 0 AND encounter_datetime BETWEEN '" + start_date.to_date.strftime('%Y-%m-%d 00:00:00') +"'
                  AND '" + end_date.to_date.strftime('%Y-%m-%d 23:59:59') + "'
                  AND program_id ='" + programID.program_id.to_s + "'
                GROUP BY enc_date"
              ).map { |e| e. patient_id }
        
              options['ids'] = data
              collection[key] = options
            end

            if key.eql?('Referal to other institutions')
              data = Observation.where("obs_datetime BETWEEN ? AND ?
              AND concept_id = ?", start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                       end_date.to_date.strftime('%Y-%m-%d 23:59:59'), '7414')\
                                .joins('LEFT JOIN location l ON l.location_id = obs.value_text')\
                                .select('obs.person_id').order('obs_datetime DESC')
              all = data.collect { |record| record.person_id }
              options['ids'] = all
              collection[key] = options
            end

            if key.eql?('HIV/AIDS - new')
              data = ActiveRecord::Base.connection.select_all(
                "SELECT * FROM temp_earliest_start_date
                WHERE date_enrolled BETWEEN '#{start_date}' AND '#{end_date}'
                AND date_enrolled = earliest_start_date
                GROUP BY patient_id" ).to_hash
              all = data.collect { |record| record['patient_id'] }
              options['ids'] = all
              collection[key] = options
            end

            if key.eql?('Measles under five years - new')
              collection[key] = disaggregate('less', concept_ids, start_date, end_date, type)
            end

            if key.eql?('Pneumonia under 5 years- new')
              collection[key] = disaggregate('less', concept_ids, start_date, end_date, type)
            end

            if key.eql?('Malaria under 5 years - new')
              collection[key] = disaggregate('less', concept_ids, start_date, end_date, type)
            end

            if key.eql?('Malaria 5 years and older - new')
              collection[key] = disaggregate('greater', concept_ids, start_date, end_date, type)
            end

            if key.eql?('Dysentery under 5 years - new')
              collection[key] = disaggregate('less', concept_ids, start_date, end_date, type)
            end

            if key.eql?('Diarrhoea non - bloody -new cases (under5)')
              collection[key] = disaggregate('less', concept_ids, start_date, end_date, type)
            end

          end
        end

        collection

      end

      def generate_notifiable_disease_conditions_report(start_date=nil, end_date=nil)
        diag_map = settings['notifiable_disease_conditions']

        start_date = Date.today.strftime('%Y-%m-%d') if start_date.nil?
        end_date = Date.today.strftime('%Y-%m-%d') if end_date.nil?

        type = EncounterType.find_by_name 'Outpatient diagnosis'
        collection = {}
        concept_name_for_sms_portal = {}

        diag_map.each do |key, value|
          options = {'<5yrs'=>nil, '>=5yrs'=>nil}
          concept_ids = ConceptName.where(name: value).collect { |cn| cn.concept_id }

          data = Encounter.where('encounter_datetime BETWEEN ? AND ?
          AND encounter_type = ? AND value_coded IN (?)
          AND concept_id IN(6543, 6542)',
                                 start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                                 end_date.to_date.strftime('%Y-%m-%d 23:59:59'), type.id, concept_ids)\
                          .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
          INNER JOIN person p ON p.person_id = encounter.patient_id')\
                          .select('encounter.encounter_type, obs.value_coded, p.*')

          # under_five
          under_five = data.select { |record| calculate_age(record['birthdate']) < 5 }\
                           .collect { |record| record.person_id }
          options['<5yrs'] = under_five
          # above 5 years
          over_five = data.select { |record| calculate_age(record['birthdate']) >=5 }\
                          .collect { |record| record.person_id }

          options['>=5yrs'] = over_five

          collection[key] = options

          concept_name_for_sms_portal[key] = concept_ids
        end
        send_data_to_sms_portal(collection, concept_name_for_sms_portal)
        return collection
      end

      # helper menthod
      def months_generator
          months = Hash.new
          count = 1
          curr_date = Date.today
          while count < 13 do
              curr_date = curr_date - 1.month
              months[curr_date.strftime('%Y%m')] = [curr_date.strftime('%B-%Y'),\
                                                    (curr_date.beginning_of_month.to_s+' to ' + curr_date.end_of_month.to_s)]
              count += 1
          end
          return months.to_a
      end

      def quarters_generator
        quarters = Hash.new

        to_quarter = Proc.new do |date|
          ((date.month - 1) / 3) + 1
        end

        init_quarter = Date.today.beginning_of_year - 2.years

        while init_quarter <= Date.today do
          quarter = init_quarter.strftime('%Y')+' Q'+to_quarter.call(init_quarter).to_s
          dates = "#{(init_quarter.beginning_of_quarter).to_s} to #{(init_quarter.end_of_quarter).to_s}"
          quarters[quarter] = dates
          init_quarter = init_quarter + 3.months
        end

        return quarters.to_a
      end

      # helper menthod
      def weeks_generator

        weeks = Hash.new
        first_day = (Date.today - (11).month).at_beginning_of_month
        wk_of_first_day = first_day.cweek

        if wk_of_first_day > 1
          wk = first_day.prev_year.year.to_s+'W'+wk_of_first_day.to_s
          dates = "#{(first_day-first_day.wday+1).to_s} to #{((first_day-first_day.wday+1)+6).to_s}"
          weeks[wk] = dates
        end

        # get the firt monday of the year
        while !first_day.monday? do
          first_day = first_day+1
        end
        first_monday = first_day
        # generate week numbers and date ranges

        while first_monday <= Date.today do
            wk = (first_monday.year).to_s+'W'+(first_monday.cweek).to_s
            dates = "#{first_monday.to_s} to #{(first_monday+6).to_s}"
            # add to the hash
            weeks[wk] = dates
            # step by week
            first_monday += 7
        end
      # remove the last week
      this_wk = (Date.today.year).to_s+'W'+(Date.today.cweek).to_s
      weeks = weeks.delete_if { |key, value| key==this_wk }

      return weeks.to_a
      end

      # Age calculator
      def calculate_age(dob)
        age = ((Date.today-dob.to_date).to_i)/365 rescue 0
      end

      def send_data(data, type)
        # method used to post data to the server
        # prepare payload here
        conn = server_config['ohsp']
        payload = {
          'dataSet' =>get_data_set_id(type),
          'period'=>(type.eql?('weekly') ? weeks_generator.last[0] : months_generator.first[0]),
          'orgUnit'=> get_ohsp_facility_id,
          'dataValues'=> []
        }
         special = ['Severe Pneumonia in under 5 cases', 'Malaria in Pregnancy',
                    'Underweight Newborns < 2500g in Under 5 Cases', 'Diarrhoea In Under 5']

        data.each do |key, value|
          if !special.include?(key)
              option1 = {'dataElement'=>get_ohsp_de_ids(key, type)[1],
                          'categoryOptionCombo'=> get_ohsp_de_ids(key, type)[2],
                          'value'=>value['<5yrs'].size } rescue {}

              option2 = {'dataElement'=>get_ohsp_de_ids(key, type)[1],
                          'categoryOptionCombo'=> get_ohsp_de_ids(key, type)[3],
                          'value'=>value['>=5yrs'].size} rescue {}

            # fill data values array
              payload['dataValues'] << option1
              payload['dataValues'] << option2
          else
              case key
                when special[0]
                  option1 = {'dataElement'=>get_ohsp_de_ids(key, type)[1],
                              'categoryOptionCombo'=> get_ohsp_de_ids(key, type)[2],
                              'value'=>value['<5yrs'].size } rescue {}

                  payload['dataValues'] << option1
                when special[1]
                  option2 = {'dataElement'=>get_ohsp_de_ids(key, type)[1],
                              'categoryOptionCombo'=> get_ohsp_de_ids(key, type)[3],
                              'value'=>value['>=5yrs'].size } rescue {}

                  payload['dataValues'] << option2
                when special[2]
                  option1 = {'dataElement'=>get_ohsp_de_ids(key, type)[1],
                              'categoryOptionCombo'=> get_ohsp_de_ids(key, type)[2],
                              'value'=>value['<5yrs'].size } rescue {}

                  payload['dataValues'] << option1
                when special[3]
                  option1 = {'dataElement'=>get_ohsp_de_ids(key, type)[1],
                              'categoryOptionCombo'=> get_ohsp_de_ids(key, type)[2],
                              'value'=>value['<5yrs'].size} rescue {}

                  payload['dataValues'] << option1
              end
          end
        end

        puts "now sending these values: #{payload.to_json}"
        url = "#{conn["url"]}/api/dataValueSets"
        puts url
        puts "pushing #{type} IDSR Reports"
        send = RestClient::Request.execute(method: :post,
                                           url: url,
                                           headers:{'Content-Type'=> 'application/json'},
                                           payload: payload.to_json,
                                            # headers: {accept: :json},
                                           user: conn['username'],
                                           password: conn['password'])

        puts send
      end

      def send_data_to_sms_portal(data, concept_name_collection)
        conn2 = server_config['idsr_sms']
        data = data.select { |k, v| v.select { |kk, vv| vv.length > 0 }.length > 0 }
        payload = {
          'email'=> conn2['username'],
          'password' => conn2['password'],
          'emr_facility_id' => Location.current_health_center.id,
          'emr_facility_name' => Location.current_health_center.name,
          'payload' => data,
          'concept_name_collection' => concept_name_collection
        }
      
     
      
        begin
          response = RestClient::Request.execute(method: :post,
                                                 url: conn2['url'],
                                                 headers:{'Content-Type'=> 'application/json'},
                                                 payload: payload.to_json
          )
        rescue RestClient::ExceptionWithResponse => res
          puts "error: #{res.class}" if res.class == RestClient::Forbidden
        end
      
        if response.class != NilClass
          puts "success: #{response}" if response.code == 200
        end
        
      end

    end
  end

end
