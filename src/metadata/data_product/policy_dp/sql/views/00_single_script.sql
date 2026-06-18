CREATE  OR  ALTER  VIEW  [policy].[vw dim business class]
    AS  
SELECT  [bus_class_key],
        [bus_class_cd_bus_key] [class code],
        [bus_class_suffix_bus_key] [class suffix],
        [bus_class_desc] [class desc],
        [bus_class_src_id_bus_key] [class src id],
        [bus_naics_cd] [class naics],
        [bus_lob] [class lob]
 FROM  [policy].[dim_business_class]
 WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim carrier]
    AS
SELECT  [carrier_key],
        [carrier_cd_bus_key] [carrier code],
        [carrier_nm] [carrier name] ,
        [carrier_type] [carrier type] 
  FROM  [policy].[dim_carrier]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim date]
    AS
SELECT  [date_key],
        [date],
        [day],
        [day_suffix],
        [day_name],
        [day_of_week],
        [day_of_week_in_month],
        [day_of_year],
        [is_weekend],
        [week],
        [iso_week],
        [first_of_week],
        [last_of_week],
        [week_of_month],
        [month],
        [month_name],
        [first_of_month],
        [last_of_month],
        [first_of_next_month],
        [last_of_next_month],
        [quarter],
        [year_quarter],
        [first_of_quarter],
        [last_of_quarter],
        [year],
        [iso_year],
        [first_of_year],
        [last_of_year],
        [is_leap_year],
        [has_53_weeks],
        [has_53_iso_weeks],
        [mmyyyy],
        [style101],
        [style103],
        [style112],
        [style120],
        [year_to_date],
        [prior_year_to_date],
        [prior_year],
        [prior_2_years],
        [trailing_12_months],
        [prior_month_ytd],
        [prior_month_pytd],
        [prior_month_ttm],
        [inforce_date_ytd],
        [inforce_date_pytd],
        [prior_month_py_ttm],
        [current_quarter],
        [prior_year_quarter]
  FROM  [policy].[dim_date]
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim decision uw]
    AS
SELECT  [emp_key],
        [emp_cd_bus_key] [emp code],
        [emp_nm] [emp name],
        [active] [is active],
        [term_dt] [termination date],
        [job_title] [job title],
        [user_id] [user id]
  FROM  [policy].[dim_employee]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim dist chnl]
    AS
SELECT  [dist_chnl_key],
        [agcy_cd_bus_key] [agency code],
        [agcy_desc] [agency desc],
        [super_agcy_cd] [super agency code],
        [super_agcy_desc] [super agency desc] ,
        tm.[emp_nm] [terr mgr],
        pra.[emp_nm] [producer relations advisor],
        [agcy_status] [agency status],
        [agcy_closed_date] [agency closed date]
  FROM  [policy].[dim_dist_chnl] dc
LEFT OUTER JOIN  [policy].[dim_employee] tm  on dc.terr_mngr_emp_key    = tm.emp_key AND tm.dl_is_current_flag = 1
LEFT OUTER JOIN  [policy].[dim_employee] pra on dc.prod_rel_adv_emp_key = pra.emp_key AND pra.dl_is_current_flag = 1
  WHERE dc.dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim insured]
    AS
SELECT  [insd_key],
        [policy_num_bus_key] [policy code],
        [mail_add1] [mail add1],
        [mail_add2] [mail add2],
        [mail_city] [mail city],
        [mail_county] [mail county],
        [mail_state] [mail state],
        [mail_zip] [mail zip],
        [insd_nm] [name],
        et.[insd_leg_ent_type_desc] [insured legal entity type],
        [bus_start_year] [insured business start year] ,
        [desc_of_ops] [description of operations],
        [crmid] [CRMID]
  FROM  [policy].[dim_insured] ins
LEFT OUTER JOIN  [policy].[dim_insured_legal_entity_type] et  on ins.legal_ent_type_key = et.[insd_leg_ent_type_key]
  WHERE ins.dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim lob]
    AS
SELECT  [lob_key],
        [lob_cd_bus_key] [lob code],
        [lob_desc] [lob description]
  FROM  [policy].[dim_lob]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW [policy].[vw dim lob product]
AS
SELECT      [lob_product_key],
            [lob_product_id_bus_key] AS [lob product id],
            [lob_product_desc] AS [lob product description],
            [lob_product_keyidentifier] AS [lob product key identifier],
            [lob_product_lob] AS [lob product lob],
            [lob_product_effectivelob] AS [lob product effective lob]
FROM  [policy].[dim_lob_product]
WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim mkt type]
    AS
SELECT  [mkt_type_key],
        [mkt_type_cd_bus_key] [market type code],
        [mkt_type_desc] [market type desc]
  FROM  [policy].[dim_mkt_type]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim naics]
    AS
SELECT  [naics_key],
        [naics_bus_key] [naics code],
        [naics_desc] [naics desc],
        [naics_industry] [naics industry],
        [naics_sub_industry] [naics sub industry],
        [naics_bus_type] [naics business type],
        [naics_two_digit] [naics two digit],
        [naics_three_digit] [naics three digit],
        [naics_four_digit] [naics four digit],
        [naics_five_digit] [naics five digit]
  FROM  [policy].[dim_naics]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim policy status]
    AS
SELECT  [policy_status_key],
        [policy_status_desc],
        [l0_level],
        [l1_level],
        [l2_level],
        [l3_level],
        [l4_level],
        [l5_level],
        ISNULL([l0_level],'') + '>' + ISNULL([l1_level],'') + '>' + ISNULL([l2_level],'') +  '>'  + ISNULL([l3_level],'') + '>' + ISNULL([l4_level],'') + '>' + ISNULL([l5_level],'') as [status_lineage]
  FROM  [policy].[dim_policy_status]
  WHERE dl_is_current_flag = 1
GO

CREATE  OR  ALTER  VIEW  [policy].[vw dim policy trans type]
    AS
SELECT  [policy_trans_type_key],
        [policy_trans_type_cd_bus_key] AS [policy trans type cd bus key],
        [policy_trans_type_desc] AS [policy trans type desc]
  FROM  [policy].[dim_policy_trans_type]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim policy trans subtype] 
    AS
SELECT  [policy_trans_subtype_key],
        [policy_trans_subtype_bus_key] [policy trans subtype src id],
        [policy_trans_cd] [policy trans code],
        [policy_trans_subtype_desc] [policy trans subtype desc],
        [policy_trans_subtype_desc_short] [policy trans subtype short desc]
  FROM  [policy].[dim_policy_trans_subtype]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim policy]
    AS
SELECT  [policy_key],
        [policy_num_bus_key] AS [policy code],
        [policy_bus_type] AS [policy business type],
        [gov_state] AS [gov state],
        [policy_effec_start_dt] AS [policy effec start date],
        [policy_effec_end_dt] AS [policy effec end date],
        [policy_coverage_start_dt] AS [policy coverage start date],
        [policy_coverage_end_dt] AS [policy coverage end date],
        [policy_cancel_dt] AS [policy cancel date],
        [policy_cancel_trans_dt] AS [policy cancel transaction date],
        [policy_audit_dt] AS [policy audit date],
        [policy_sub_dt] AS [policy sub date],
        [policy_issue_dt] AS [policy issue date],
        [offer_rn] AS [offer renewal],
        [previous_policy_num_bus_key] AS [previous policy code],
        [next_policy_num_bus_key] AS [next policy code],
        [chain_id] AS [chain id],
        [first_dwnpymnt_recd_dt] AS [first downpayment recd date],
        [rewritten_reissued_ind] AS [rewritten reissued ind],
        [is_expiring_flag] AS [is expiring flag],
        [is_renewable_flag] AS [is renewable flag],
        [is_prev_policy_ubetag_flag] AS [is previous policy ube tagged flag],
        [is_cloned_flag] AS [is cloned flag],
        [src_policy_status_descrip] AS [source policy status description],
        [policy_status_desc] AS [latest policy status],
        [latest_policy_status_key],
        stat.status_lineage,
        dds.digital_decision_status_lineage
  FROM  [policy].[dim_policy] p
LEFT OUTER JOIN  [policy].[vw dim policy status] stat  ON p.latest_policy_status_key = stat.[policy_status_key]
LEFT OUTER JOIN  [policy].[vw dim digital decision status] dds  ON p.digital_decision_status_key = dds.[digital_decision_status_key]
GO
CREATE  OR  ALTER  VIEW  [policy].[vw dim prod src]
    AS
SELECT  [prod_src_key],
        [prod_src_cd_bus_key] [prod src code],
        [prod_src_desc] [prod src desc]
  FROM  [policy].[dim_prod_src]
  WHERE dl_is_current_flag = 1
GO
CREATE  OR  ALTER  VIEW [policy].[vw fact policy]
AS
SELECT      fp.[policy_key], dp.[policy code],
            dp.[status_lineage],
            
            fp.[dec_prem] AS [declaration prem],
            fp.[dw_prem] AS [direct written prem],
            dp.[gov state],

            car.[carrier name],

            lob.[lob code],
            lob.[lob description],
            
            dt.[year] AS [policy start year], 
            dt.[month] AS [policy start month], 
            dt.[mmyyyy] AS [policy start mmyyyy], 
            dt.[date] AS [policy start date],
            dt.[year_quarter] AS [policy start year-quarter], 

            end_dt.[year] AS [policy end year], 
            end_dt.[month] AS [policy end month], 
            end_dt.[mmyyyy] AS [policy end mmyyyy], 
            end_dt.[date] AS [policy end date],
            end_dt.[year_quarter] AS [policy end year-quarter], 
 
            coverage_start_dt.[year] AS [policy coverage start year], 
            coverage_start_dt.[month] AS [policy coverage start month], 
            coverage_start_dt.[mmyyyy] AS [policy coverage start mmyyyy], 
            coverage_start_dt.[date] AS [policy coverage start date],
            coverage_start_dt.[year_quarter] AS [policy coverage start year-quarter], 

            coverage_end_dt.[year] AS [policy coverage end year], 
            coverage_end_dt.[month] AS [policy coverage end month], 
            coverage_end_dt.[mmyyyy] AS [policy coverage end mmyyyy], 
            coverage_end_dt.[date] AS [policy coverage end date],
            coverage_end_dt.[year_quarter] AS [policy coverage end year-quarter], 

            cancel_dt.[year] AS [policy cancel year], 
            cancel_dt.[month] AS [policy cancel month], 
            cancel_dt.[mmyyyy] AS [policy cancel mmyyyy], 
            cancel_dt.[date] AS [policy cancel date],
            cancel_dt.[year_quarter] AS [policy cancel year-quarter], 

            dp.[policy issue date],
            dp.[policy cancel transaction date],

            uw.[emp code] AS [dec uw Code], 
            uw.[emp name] AS [dec uw Name], 

            dc.[agency code],
            dc.[agency desc],
            dc.[super agency code],
            dc.[super agency desc],
            dc.[terr mgr],

            naics.[naics code],
            naics.[naics desc],

            mt.[market type code],
            mt.[market type desc],

            ps.[prod src code],
            ps.[prod src desc],

            lp.[lob product id],
            lp.[lob product description],

            dp.[digital_decision_status_lineage],

            CASE WHEN dp.[is expiring flag] = 1                                     THEN 1 ELSE 0 END AS [is expiring],
            dp.[is renewable flag]                                                                    AS [is renewable],
            CASE WHEN dp.[is previous policy ube tagged flag] = 1                   THEN 1 ELSE 0 END AS [is previous policy ube tagged],
            CASE WHEN dp.[is cloned flag] = 1                                       THEN 1 ELSE 0 END AS [is cloned],

            fp.[nb_submitted_prem] AS [new business submitted premium],            
            fp.[nb_submitted_count] AS [new business submitted count],            
            fp.[nb_quoted_prem] AS [new business quoted premium],                  
            fp.[nb_quoted_count] AS [new business quoted count],               
            fp.[nb_issued_prem] AS [new business issued premium],                
            fp.[nb_issued_count] AS [new business issued count],
            fp.[rn_quoted_prem] AS [renewal quoted premium],                
            fp.[rn_quoted_count] AS [renewal quoted count],               
            fp.[rn_issued_prem] AS [renewal issued premium],                
            fp.[rn_issued_count] AS [renewal issued count],               
            fp.[rn_issued_dwnpymnt_recd_prem] AS [renewal issued down payment received premium],  
            fp.[rn_issued_dwnpymnt_recd_count] AS [renewal issued down payment received count],               
            fp.[expiring_prem] AS [expiring premium],                 
            fp.[expiring_count] AS [expiring count],                
            fp.[expiring_renewable_prem] AS [expiring renewable premium],        
            fp.[expiring_renewable_count] AS [expiring renewable count],      
            fp.[next_policy_quoted_prem] AS [next policy quoted premium],                
            fp.[next_policy_quoted_count] AS [next policy quoted count], 

            fp.[policy_sub_dt_key],
            fp.[policy_effec_start_dt_key],
            fp.[policy_effec_end_dt_key],
            fp.[policy_cancel_dt_key],
            fp.[policy_coverage_start_dt_key],
            fp.[policy_coverage_end_dt_key],
            fp.[policy_issue_dt_key],
            fp.[policy_audit_dt_key],

            fp.[dist_chnl_key],
            fp.[naics_key],
            fp.[dec_uw_emp_key],
            fp.[carrier_key],
            fp.[entered_by_emp_key],
            fp.[insd_key],
            fp.[gov_bus_class_key],
            fp.[lob_product_key]
            
FROM [den_lhw_dpr_001_policy_product].[policy].[fact_policy] fp
LEFT OUTER JOIN [policy].[vw dim policy]      dp                ON fp.[policy_key]                   = dp.[policy_key]
LEFT OUTER JOIN [policy].[vw dim carrier]     car               ON car.[carrier_key]                 = fp.[carrier_key]
LEFT OUTER JOIN [policy].[vw dim lob]         lob               ON lob.[lob_key]                     = fp.[lob_key]
LEFT OUTER JOIN [policy].[vw dim date]        dt                ON fp.[policy_effec_start_dt_key]    = dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        end_dt            ON fp.[policy_effec_end_dt_key]      = end_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        coverage_start_dt ON fp.[policy_coverage_start_dt_key] = coverage_start_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        coverage_end_dt   ON fp.[policy_coverage_end_dt_key]   = coverage_end_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        cancel_dt         ON fp.[policy_cancel_dt_key]         = cancel_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim decision uw] uw                ON uw.[emp_key]                      = fp.[dec_uw_emp_key]
LEFT OUTER JOIN [policy].[vw dim dist chnl]   dc                ON dc.[dist_chnl_key]                = fp.[dist_chnl_key]
LEFT OUTER JOIN [policy].[vw dim insured]     ins               ON ins.[insd_key]                    = fp.[insd_key]
LEFT OUTER JOIN [policy].[vw dim mkt type]    mt                ON mt.[mkt_type_key]                 = fp.[mkt_type_key] 
LEFT OUTER JOIN [policy].[vw dim naics]       naics             ON naics.[naics_key]                 = fp.[naics_key]
LEFT OUTER JOIN [policy].[vw dim prod src]    ps                ON ps.[prod_src_key]                 = fp.[prod_src_key]
LEFT OUTER JOIN [policy].[vw dim lob product] lp                ON lp.[lob_product_key]              = fp.[lob_product_key]
GO
CREATE  OR  ALTER  VIEW  [policy].[vw fact policy transaction]
    AS
SELECT  fp.[policy_key],
        dp.[policy code],
	fp.[policy_trans_seq_num] AS [policy transaction sequence number],
	fp.[src_trans_id_type] AS [policy transaction id type],
	fp.[src_trans_id] AS [source transaction id],
	fp.[prem_amt] AS [premium amount],
	fp.[fsa_amt] AS [fsa amount],
	fp.[paa_amt] AS [paa amount],
	fp.[sf3_amt] AS [sf3 amount],
	fp.[sf4_amt] AS [sf4 amount],
	fp.[sf5_amt] AS [sf5 amount],
	fp.[sf6_amt] AS [sf6 amount],
	fp.[sf7_amt] AS [sf7 amount],
	fp.[comm_amt] AS [commission amount],
	fp.[non_comm_prem_amt] AS [non commission premium amount],
	fp.[policy_trans_state] AS [policy transaction state],

        dt.[year] AS [policy start year], 
        dt.[month] AS [policy start month], 
        dt.[mmyyyy] AS [policy start mmyyyy], 
        dt.[date] AS [policy start date],
        dt.[year_quarter] AS [policy start year-quarter],

        end_dt.[year] AS [policy end year], 
        end_dt.[month] AS [policy end month], 
        end_dt.[mmyyyy] AS [policy end mmyyyy], 
        end_dt.[date] AS [policy end date],
        end_dt.[year_quarter] AS [policy end year-quarter],

        coverage_start_dt.[year] AS [policy coverage start year], 
        coverage_start_dt.[month] AS [policy coverage start month], 
        coverage_start_dt.[mmyyyy] AS [policy coverage start mmyyyy], 
        coverage_start_dt.[date] AS [policy coverage start date],
        coverage_start_dt.[year_quarter] AS [policy coverage start year-quarter],

        coverage_end_dt.[year] AS [policy coverage end year], 
        coverage_end_dt.[month] AS [policy coverage end month], 
        coverage_end_dt.[mmyyyy] AS [policy coverage end mmyyyy], 
        coverage_end_dt.[date] AS [policy coverage end date],
        coverage_end_dt.[year_quarter] AS [policy coverage end year-quarter],

        treffc_dt.[year] AS [transaction effective year], 
        treffc_dt.[month] AS [transaction effective month], 
        treffc_dt.[mmyyyy] AS [transaction effective mmyyyy], 
        treffc_dt.[date] AS [transaction effective date],
        treffc_dt.[year_quarter] AS [transaction effective year-quarter],

        trdate_dt.[year] AS [transaction date year], 
        trdate_dt.[month] AS [transaction date month], 
        trdate_dt.[mmyyyy] AS [transaction date mmyyyy], 
        trdate_dt.[date] AS [transaction date date],
        trdate_dt.[year_quarter] AS [transaction date year-quarter],

        trwrit_dt.[year] AS [transaction written on year], 
        trwrit_dt.[month] AS [transaction written on month], 
        trwrit_dt.[mmyyyy] AS [transaction written on mmyyyy], 
        trwrit_dt.[date] AS [transaction written on date],
        trwrit_dt.[year_quarter] AS [transaction written on year-quarter],

        car.[carrier name],
        lob.[lob code],
        lob.[lob description], 
        dc.[agency code],
        dc.[agency desc],
        dc.[super agency code],
        dc.[super agency desc],
        dc.[terr mgr],
        naics.[naics code],
        naics.[naics desc],
        uw.[emp code] AS [dec uw Code], 
        uw.[emp name] AS [dec uw Name], 
        mt.[market type code],
        mt.[market type desc],
        ps.[prod src code],
        ps.[prod src desc],
	tt.[policy trans type cd bus key],
	tt.[policy trans type desc],
        lp.[lob product id],
        lp.[lob product description],

	fp.[policy_effec_start_dt_key],
	fp.[policy_effec_end_dt_key],
	fp.[policy_coverage_start_dt_key],
	fp.[policy_coverage_end_dt_key],
	fp.[lob_key],
	fp.[dist_chnl_key],
	fp.[insd_key],
	fp.[naics_key],
	fp.[dec_uw_emp_key],
	fp.[mkt_type_key],
	fp.[prod_src_key],
	fp.[carrier_key],
	fp.[policy_trans_type_key],
	fp.[policy_trans_effec_dt_key],
	fp.[policy_trans_dt_key],
	fp.[policy_trans_written_on_dt_key],
	fp.[gov_bus_class_key],
        fp.[lob_product_key]

  FROM  [policy].[fact_policy_transaction]  fp
LEFT OUTER JOIN [policy].[vw dim policy]      dp                ON fp.[policy_key]                   = dp.[policy_key]
LEFT OUTER JOIN [policy].[vw dim carrier]     car               ON car.[carrier_key]                 = fp.[carrier_key]
LEFT OUTER JOIN [policy].[vw dim lob]         lob               ON lob.[lob_key]                     = fp.[lob_key]
LEFT OUTER JOIN [policy].[vw dim date]        dt                ON fp.[policy_effec_start_dt_key]    = dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        end_dt            ON fp.[policy_effec_end_dt_key]      = end_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        coverage_start_dt ON fp.[policy_coverage_start_dt_key] = coverage_start_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        coverage_end_dt   ON fp.[policy_coverage_end_dt_key]   = coverage_end_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        treffc_dt         ON fp.[policy_trans_effec_dt_key]    = treffc_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        trdate_dt         ON fp.[policy_trans_dt_key]          = trdate_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        trwrit_dt         ON fp.[policy_trans_written_on_dt_key] = trwrit_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim decision uw] uw                ON uw.[emp_key]                      = fp.[dec_uw_emp_key]
LEFT OUTER JOIN [policy].[vw dim dist chnl]   dc                ON dc.[dist_chnl_key]                = fp.[dist_chnl_key]
LEFT OUTER JOIN [policy].[vw dim insured]     ins               ON ins.[insd_key]                    = fp.[insd_key]
LEFT OUTER JOIN [policy].[vw dim mkt type]    mt                ON mt.[mkt_type_key]                 = fp.[mkt_type_key] 
LEFT OUTER JOIN [policy].[vw dim naics]       naics             ON naics.[naics_key]                 = fp.[naics_key]
LEFT OUTER JOIN [policy].[vw dim prod src]    ps                ON ps.[prod_src_key]                 = fp.[prod_src_key]
LEFT OUTER JOIN [policy].[vw dim policy trans type] tt          ON tt.[policy_trans_type_key]        = fp.[policy_trans_type_key]
LEFT OUTER JOIN [policy].[vw dim lob product] lp                ON lp.[lob_product_key]              = fp.[lob_product_key]
GO
CREATE  OR  ALTER  VIEW  [policy].[vw fact policy transaction detail]
    AS
SELECT  fp.[policy_key],
        dp.[policy code],
	fp.[policy_trans_seq_num]  AS  [policy transaction sequence number],
	fp.[src_trans_detail_id] AS [source transaction detail id],
	fp.[extra_info] AS [extra information],
	fp.[additional_info] AS [additional information],
	fp.[reason_cd] AS [reason code],

        dt.[year] AS [policy start year], 
        dt.[month] AS [policy start month], 
        dt.[mmyyyy] AS [policy start mmyyyy], 
        dt.[date] AS [policy start date],
        dt.[year_quarter] AS [policy start year-quarter],

        end_dt.[year] AS [policy end year], 
        end_dt.[month] AS [policy end month], 
        end_dt.[mmyyyy] AS [policy end mmyyyy], 
        end_dt.[date] AS [policy end date],
        end_dt.[year_quarter] AS [policy end year-quarter],

        coverage_start_dt.[year] AS [policy coverage start year], 
        coverage_start_dt.[month] AS [policy coverage start month], 
        coverage_start_dt.[mmyyyy] AS [policy coverage start mmyyyy], 
        coverage_start_dt.[date] AS [policy coverage start date],
        coverage_start_dt.[year_quarter] AS [policy coverage start year-quarter],

        coverage_end_dt.[year] AS [policy coverage end year], 
        coverage_end_dt.[month] AS [policy coverage end month], 
        coverage_end_dt.[mmyyyy] AS [policy coverage end mmyyyy], 
        coverage_end_dt.[date] AS [policy coverage end date],
        coverage_end_dt.[year_quarter] AS [policy coverage end year-quarter],

        treffc_dt.[year] AS [transaction effective year], 
        treffc_dt.[month] AS [transaction effective month], 
        treffc_dt.[mmyyyy] AS [transaction effective mmyyyy], 
        treffc_dt.[date] AS [transaction effective date],
        treffc_dt.[year_quarter] AS [transaction effective year-quarter],

        trdate_dt.[year] AS [transaction date year], 
        trdate_dt.[month] AS [transaction date month], 
        trdate_dt.[mmyyyy] AS [transaction date mmyyyy], 
        trdate_dt.[date] AS [transaction date date],
        trdate_dt.[year_quarter] AS [transaction date year-quarter],

        car.[carrier name],
        lob.[lob code],
        lob.[lob description], 
        dc.[agency code],
        dc.[agency desc],
        dc.[super agency code],
        dc.[super agency desc],
        dc.[terr mgr],
        naics.[naics code],
        naics.[naics desc],
        uw.[emp code] AS [dec uw Code], 
        uw.[emp name] AS [dec uw Name], 
        mt.[market type code],
        mt.[market type desc],
        ps.[prod src code],
        ps.[prod src desc],
	tt.[policy trans type cd bus key],
	tt.[policy trans type desc],
	ts.[policy trans subtype src id],
	ts.[policy trans code],
	ts.[policy trans subtype desc],
	ts.[policy trans subtype short desc],
        lp.[lob product id],
        lp.[lob product description],

	fp.[policy_effec_start_dt_key],
	fp.[policy_effec_end_dt_key],
	fp.[policy_coverage_start_dt_key],
	fp.[policy_coverage_end_dt_key],
	fp.[lob_key],
	fp.[dist_chnl_key],
	fp.[insd_key],
	fp.[naics_key],
	fp.[dec_uw_emp_key],
	fp.[mkt_type_key],
	fp.[prod_src_key],
	fp.[carrier_key],
	fp.[policy_trans_type_key],
	fp.[policy_trans_effec_dt_key],
	fp.[policy_trans_dt_key],
	fp.[policy_trans_subtype_key],
	fp.[gov_bus_class_key],
        fp.[lob_product_key]
  FROM  [policy].[fact_policy_transaction_detail]  fp
LEFT OUTER JOIN [policy].[vw dim policy]      dp                ON fp.[policy_key]                   = dp.[policy_key]
LEFT OUTER JOIN [policy].[vw dim carrier]     car               ON car.[carrier_key]                 = fp.[carrier_key]
LEFT OUTER JOIN [policy].[vw dim lob]         lob               ON lob.[lob_key]                     = fp.[lob_key]
LEFT OUTER JOIN [policy].[vw dim date]        dt                ON fp.[policy_effec_start_dt_key]    = dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        end_dt            ON fp.[policy_effec_end_dt_key]      = end_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        coverage_start_dt ON fp.[policy_coverage_start_dt_key] = coverage_start_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        coverage_end_dt   ON fp.[policy_coverage_end_dt_key]   = coverage_end_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        treffc_dt         ON fp.[policy_trans_effec_dt_key]    = treffc_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim date]        trdate_dt         ON fp.[policy_trans_dt_key]          = trdate_dt.[date_key]
LEFT OUTER JOIN [policy].[vw dim decision uw] uw                ON uw.[emp_key]                      = fp.[dec_uw_emp_key]
LEFT OUTER JOIN [policy].[vw dim dist chnl]   dc                ON dc.[dist_chnl_key]                = fp.[dist_chnl_key]
LEFT OUTER JOIN [policy].[vw dim insured]     ins               ON ins.[insd_key]                    = fp.[insd_key]
LEFT OUTER JOIN [policy].[vw dim mkt type]    mt                ON mt.[mkt_type_key]                 = fp.[mkt_type_key] 
LEFT OUTER JOIN [policy].[vw dim naics]       naics             ON naics.[naics_key]                 = fp.[naics_key]
LEFT OUTER JOIN [policy].[vw dim prod src]    ps                ON ps.[prod_src_key]                 = fp.[prod_src_key]
LEFT OUTER JOIN [policy].[vw dim policy trans type] tt          ON tt.[policy_trans_type_key]        = fp.[policy_trans_type_key]
LEFT OUTER JOIN [policy].[vw dim policy trans subtype] ts       ON ts.[policy_trans_subtype_key]     = fp.[policy_trans_subtype_key]
LEFT OUTER JOIN [policy].[vw dim lob product] lp                ON lp.[lob_product_key]              = fp.[lob_product_key]
GO
CREATE  OR  ALTER  VIEW  [policy].[vw nb - count ratio]
    AS
SELECT  [lob description],
        [policy start year],
        [policy start month],
        [policy start mmyyyy],
        [carrier name],
        [naics code],
        [agency code],
        [gov state],
        [market type desc],

        SUM([new business submitted premium]) AS [new business submitted premium],            
        SUM([new business submitted count])   AS [new business submitted count],            
        SUM([new business quoted premium])    AS [new business quoted premium],                  
        SUM([new business quoted count])      AS [new business quoted count],               
        SUM([new business issued premium])    AS [new business issued premium],                
        SUM([new business issued count])      AS [new business issued count]               

  FROM  [policy].[vw fact policy]
 WHERE  lower(status_lineage) like '%nb - new submission%'
 GROUP BY  [lob description],
           [policy start year],
           [policy start month],
           [policy start mmyyyy],
           [carrier name],
           [naics code],
           [agency code],
           [gov state],
           [market type desc]
GO
CREATE  OR  ALTER  VIEW  [policy].[vw nb - issued]
    AS
SELECT  *
  FROM  [policy].[vw fact policy]
 WHERE  Lower([status_lineage]) like '%nb - total written%'
GO
CREATE  OR  ALTER  VIEW  [policy].[vw nb - new submission]
    AS
SELECT  *
  FROM  [policy].[vw fact policy]
 WHERE  Lower([status_lineage]) like '%nb - new submission%'
GO
CREATE  OR  ALTER  VIEW  [policy].[vw nb - quoted]
    AS
SELECT  *
  FROM  [policy].[vw fact policy]
 WHERE  lower([status_lineage]) like '%nb - quoted%'
GO
CREATE  OR  ALTER  VIEW  [policy].[vw rn - count ratio]
    AS
SELECT  [lob description],
        [policy start year],
        [policy start month],
        [policy start mmyyyy],
        [carrier name],
        [naics code],
        [agency code],
        [gov state],
        [market type desc],

        SUM([expiring premium])                                AS [expiring premium],                 
        SUM([expiring count])                                  AS [expiring count],                
        SUM([expiring renewable premium])                      AS [expiring renewable premium],        
        SUM([expiring renewable count])                        AS [expiring renewable count],      
        SUM([next policy quoted premium])                      AS [next policy quoted premium],                
        SUM([next policy quoted count])                        AS [next policy quoted count],
        SUM([renewal quoted premium])                          AS [renewal quoted premium],                
        SUM([renewal quoted count])                            AS [renewal quoted count],                   
        SUM([renewal issued premium])                          AS [renewal issued premium],                
        SUM([renewal issued count])                            AS [renewal issued count],               
        SUM([renewal issued down payment received premium])    AS [renewal issued down payment received premium],  
        SUM([renewal issued down payment received count])      AS [renewal issued down payment received count]

  FROM  [policy].[vw fact policy]
 WHERE  lower(status_lineage) like '%rn - renewal%'
 GROUP BY  [lob description],
           [policy start year],
           [policy start month],
           [policy start mmyyyy],
           [carrier name],
           [naics code],
           [agency code],
           [gov state],
           [market type desc]
GO
CREATE  OR  ALTER  VIEW  [policy].[vw rn - renewal]
    AS
SELECT  *
  FROM  [policy].[vw fact policy]
 WHERE  Lower([status_lineage]) like '%rn - renewal%'
GO
CREATE  OR  ALTER  VIEW [policy].[vw inforce policy]
AS
SELECT  dp.[policy_key]            AS  [policy_key]
     ,  dp.[policy_num_bus_key]    AS  [policy code]
     ,  dp.[policy_bus_type]       AS  [policy business type]
     ,  CASE
        WHEN  dp.policy_effec_start_dt  >  dp.policy_issue_dt
        THEN  CAST(dp.policy_effec_start_dt AS DATE)
        ELSE  CAST(dp.policy_issue_dt       AS DATE)
        END                        AS  [inforce start date]
     ,  CASE
        WHEN  dp.policy_effec_end_dt <> dp.policy_coverage_end_dt
        THEN  CASE
              WHEN  dp.policy_cancel_dt  >  dp.policy_cancel_trans_dt
              THEN  CAST(dp.policy_cancel_dt AS DATE)
              WHEN  dp.policy_cancel_trans_dt  <  dp.policy_effec_end_dt
              THEN  CAST(dp.policy_cancel_trans_dt  AS DATE)
              ELSE  CAST(dp.policy_effec_end_dt AS DATE)
              END
        ELSE  CAST(dp.policy_effec_end_dt AS DATE)
        END                        AS  [inforce end date]
     ,  dp.gov_state               AS  [gov state]
     ,  car.carrier_nm             AS  [carrier name]
     ,  lob.lob_cd_bus_key         AS  [lob code]
     ,  lob.lob_desc               AS  [lob desc]
     ,  mt.mkt_type_cd_bus_key     AS  [market type code]
     ,  mt.mkt_type_desc           AS  [market type desc]
     ,  dc.agcy_cd_bus_key         AS  [agency code]
     ,  dc.agcy_desc               AS  [agency desc]
     ,  dc.super_agcy_cd           AS  [super agency code]
     ,  dc.super_agcy_desc         AS  [super agency desc]
     ,  lp.lob_product_id_bus_key  AS  [lob product id]
     ,  lp.lob_product_desc        AS  [lob product description]
  FROM             [policy].[dim_policy]            dp
  LEFT OUTER JOIN  [policy].[fact_policy]           fp
    ON  dp.policy_key                =  fp.policy_key
  LEFT OUTER JOIN  [policy].[dim_carrier]           car
    ON  fp.[carrier_key]             =  car.[carrier_key]
  LEFT OUTER JOIN  [policy].[dim_lob]               lob
    ON  fp.[lob_key]                 =  lob.[lob_key]
  LEFT OUTER JOIN  [policy].[dim_mkt_type]          mt
    ON  fp.[mkt_type_key]            = mt.[mkt_type_key]
  LEFT OUTER JOIN  [policy].[dim_naics]             naics
    ON  fp.[naics_key]               = naics.[naics_key]
  LEFT OUTER JOIN  [policy].[dim_dist_chnl]         dc
    ON  fp.[dist_chnl_key]           = dc.[dist_chnl_key]
  LEFT OUTER JOIN  [policy].[dim_lob_product]       lp
    ON  fp.[lob_product_key]         = lp.[lob_product_key]
 WHERE dp.policy_issue_dt        IS NOT NULL
GO
CREATE  OR  ALTER  VIEW  [policy].[vw digitally decisioned]
    AS  
SELECT  dp.[policy_key]            AS  [policy_key]
     ,  dp.[policy_num_bus_key]    AS  [policy code]
     ,  dp.[policy_bus_type]       AS  [policy business type]
     ,  dp.gov_state               AS  [gov state]
     ,  car.carrier_nm             AS  [carrier name]
     ,  lob.lob_cd_bus_key         AS  [lob code]
     ,  lob.lob_desc               AS  [lob desc]
     ,  mt.mkt_type_cd_bus_key     AS  [market type code]
     ,  mt.mkt_type_desc           AS  [market type desc]
     ,  dc.agcy_cd_bus_key         AS  [agency code]
     ,  dc.agcy_desc               AS  [agency desc]
     ,  dc.super_agcy_cd           AS  [super agency code]
     ,  dc.super_agcy_desc         AS  [super agency desc]
     ,  lp.lob_product_id_bus_key  AS  [lob product id]
     ,  lp.lob_product_desc        AS  [lob product description]
     ,  CASE
        WHEN  dd.digital_decision_status_cd_bus_key  LIKE  'Digitally Decisioned%'
        THEN  1
        ELSE  0
        END                        AS  [digitally decisioned count]
     ,  CASE
        WHEN  dd.digital_decision_status_cd_bus_key  LIKE  'Mitigating Circumstances%'
        THEN  1
        ELSE  0
        END                        AS  [mitigating circumstances count]
     ,  CASE
        WHEN  dd.digital_decision_status_cd_bus_key  LIKE  'Digitally Assisted%'
        THEN  1
        ELSE  0
        END                        AS  [digitally assisted count]
     ,  CASE
        WHEN  dd.digital_decision_status_cd_bus_key  LIKE  'Manual / Supplemental%'
        THEN  1
        ELSE  0
        END                        AS  [manual supplemental count]
     ,  CASE
        WHEN  dd.digital_decision_status_cd_bus_key  LIKE  'Incomplete%'
        THEN  1
        ELSE  0
        END                        AS  [incomplete count]
     ,  CASE
        WHEN  dd.digital_decision_status_cd_bus_key  LIKE  'Excluded From Digital%'
        THEN  1
        ELSE  0
        END                        AS  [excluded count]
     ,  dd.digital_decision_status_cd_bus_key  AS  [digital decision status description]
     ,  fp.[nb_submitted_prem]     AS  [new business submitted premium]            
     ,  fp.[nb_submitted_count]    AS  [new business submitted count]            
     ,  fp.[nb_quoted_prem]        AS  [new business quoted premium]                  
     ,  fp.[nb_quoted_count]       AS  [new business quoted count]               
     ,  fp.[nb_issued_prem]        AS  [new business issued premium]                
     ,  fp.[nb_issued_count]       AS  [new business issued count]
  FROM             [policy].[dim_policy]            dp
  LEFT OUTER JOIN  [policy].[fact_policy]           fp
    ON  dp.[policy_key]              =  fp.[policy_key]
  LEFT OUTER JOIN  [policy].[dim_carrier]           car
    ON  fp.[carrier_key]             =  car.[carrier_key]
  LEFT OUTER JOIN  [policy].[dim_lob]               lob
    ON  fp.[lob_key]                 =  lob.[lob_key]
  LEFT OUTER JOIN  [policy].[dim_mkt_type]          mt
    ON  fp.[mkt_type_key]            = mt.[mkt_type_key]
  LEFT OUTER JOIN  [policy].[dim_naics]             naics
    ON  fp.[naics_key]               = naics.[naics_key]
  LEFT OUTER JOIN  [policy].[dim_dist_chnl]         dc
    ON  fp.[dist_chnl_key]           = dc.[dist_chnl_key]
  LEFT OUTER JOIN  [policy].[dim_lob_product]       lp
    ON  fp.[lob_product_key]         = lp.[lob_product_key]
  LEFT OUTER JOIN  [policy].[dim_digital_decision_status]  dd
    ON  dp.[digital_decision_status_key]  = dd.[digital_decision_status_key]
 WHERE  dp.digital_decision_status_key  NOT IN (-1,-2)
GO