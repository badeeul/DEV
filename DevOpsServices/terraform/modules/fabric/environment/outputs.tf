
# output "environment_ids" {
#   value = {
#     for ws_name, env in fabric_environment.this : ws_name => {
#       id = env.id,
#       display_name = local.environment_map[ws_name].display_name,
#       logical_id = local.environment_map[ws_name].logical_id
#     }
#   }
# }

output "environment_ids" {
  value = {
    for k, v in local.environment_map :substr(k, 0, length(k) - length(split("-", k)[length(split("-", k)) - 1]) - 1) => {
      id = data.local_file.environment_ids[k].content
      display_name = v.display_name
      logical_id = v.logical_id
    }
  }
 
  depends_on = [data.local_file.environment_ids]
}