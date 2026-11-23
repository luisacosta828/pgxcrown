SELECT {{project_snake}}_hook_reset() AS hook_armed;
SELECT 42 AS probe_select;
SELECT {{project_snake}}_hook_stats() = 'label={{hook_label}}|installed=true|total=2|selects=2' AS hook_stats_ok;
