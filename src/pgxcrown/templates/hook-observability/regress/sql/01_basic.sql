SELECT {{project_snake}}_hook_reset() AS hook_armed;
SELECT {{project_snake}}_hook_enabled() AS enabled_default;

SET {{guc_prefix}}.enabled = off;
SELECT {{project_snake}}_hook_enabled() AS enabled_off;
SELECT 101 AS ignored_while_disabled;
SELECT {{project_snake}}_hook_stats() = 'label={{hook_label}}|installed=true|enabled=false|parsed=0|selects=0|exec_end=0' AS disabled_stats_ok;

SET {{guc_prefix}}.enabled = on;
SELECT {{project_snake}}_hook_enabled() AS enabled_on;
SELECT 42 AS probe_select;
SELECT {{project_snake}}_hook_stats() = 'label={{hook_label}}|installed=true|enabled=true|parsed=1|selects=1|exec_end=1' AS enabled_stats_ok;

SELECT {{project_snake}}_hook_reset() AS hook_reset_ok;
SELECT {{project_snake}}_hook_stats() = 'label={{hook_label}}|installed=true|enabled=true|parsed=0|selects=0|exec_end=0' AS reset_stats_ok;
