module EmrOhspInterface
    module Utils
        def lab_results(test_types:, start_date:, end_date:)
            test_type_ids = ConceptName.where(name: test_types).pluck(:concept_id)

            ActiveRecord::Base.connection.select_all <<~SQL
                SELECT lab.patient_id,
                   tt.name,
                   COALESCE(result.value_numeric, result.value_text,
                           result.value_coded) AS results,
                   p.birthdate
                FROM orders
                        INNER JOIN encounter lab ON lab.patient_id = orders.patient_id
                    AND lab.encounter_datetime >= '#{start_date}'
                    AND lab.encounter_datetime <= '#{end_date}'
                    AND lab.program_id = #{Program.find_by_name('OPD Program').program_id}
                    AND lab.voided = 0
                    AND orders.voided = 0
                        INNER JOIN obs test_type ON test_type.encounter_id = lab.encounter_id
                    AND test_type.concept_id = #{ConceptName.find_by_name('Test type').concept_id}
                    AND test_type.value_coded IN (#{test_type_ids.join(', ')})
                        INNER JOIN concept_name tt ON tt.concept_id = test_type.value_coded
                        INNER JOIN obs tr ON tr.order_id = orders.order_id
                    AND tr.voided = 0
                    AND tr.concept_id = #{ConceptName.find_by_name('Lab test result').concept_id}
                    AND tr.obs_group_id = test_type.obs_id
                        INNER JOIN obs result ON result.obs_group_id = tr.obs_id
                        INNER JOIN person p ON p.person_id = lab.patient_id
                GROUP BY lab.patient_id
              SQL
        end
    end
end