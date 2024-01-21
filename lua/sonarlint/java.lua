local M = {}

M.classpaths_result = nil
M._co = {}

local utils = require("sonarlint.utils")

function M.handle_progress(err, msg, info)
   local client = vim.lsp.get_client_by_id(info.client_id)

   if client.name ~= "jdtls" then
      return
   end
   if msg.value.kind ~= "end" then
      return
   end

   -- TODO: checking the message text seems a little bit brittle. Is there a better way to
   -- determine if jdtls has classpath information ready
   if msg.value.message ~= "Synchronizing projects" then
      return
   end

   require("jdtls.util").with_classpaths(function(result)
      M.classpaths_result = result

      for _, co in ipairs(M._co) do
         coroutine.resume(co, M.classpaths_result)
      end
      M._co = {}

      local sonarlint = utils.get_sonarlint_client()
      sonarlint.notify("sonarlint/didClasspathUpdate", {
         projectUri = result.projectRoot,
      })
   end)
end

function M.get_java_config_handler(err, file_uri)
   local uri = type(file_uri) == "table" and file_uri[1] or file_uri

   if M.classpaths_result then
      return request_settings(uri, M.classpaths_result)
   else
      local co = coroutine.create(function(classpaths_result)
         return request_settings(uri, classpaths_result)
      end)

      table.insert(M._co, co)

      return coroutine.yield(co)
   end
end

function request_settings(uri, classpaths_result)
   local bufnr = vim.uri_to_bufnr(uri)

   local err, is_test_file = require("jdtls.util").execute_command({
      command = "java.project.isTestFile",
      arguments = { uri },
   }, nil, bufnr)

   local err, settings = require("jdtls.util").execute_command({
      command = "java.project.getSettings",
      arguments = {
         uri,
         {
            "org.eclipse.jdt.core.compiler.source",
            "org.eclipse.jdt.ls.core.vm.location",
         },
      },
   }, nil, bufnr)

   local config = (utils.get_sonarlint_client() or {}).config or {}
   local vm_location = nil
   local source_level = nil

   if settings then
      vm_location = settings["org.eclipse.jdt.ls.core.vm.location"]
      source_level = settings["org.eclipse.jdt.core.compiler.source"]
   end

   return {
      projectRoot = classpaths_result.projectRoot or "file:" .. config.root_dir,
      sourceLevel = source_level or "11",
      classpath = classpaths_result.classpaths or {},
      isTest = is_test_file,
      vmLocation = vm_location,
   }
end

return M
