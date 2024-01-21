local M = {}

M.client_id = nil

local java = require("sonarlint.java")
local utils = require("sonarlint.utils")

local function init_with_config_notify(original_init, original_settings)
   return function(...)
      local client = select(1, ...)
      client.config.settings = vim.tbl_deep_extend("force", client.config.settings, original_settings)

      -- https://github.com/SonarSource/sonarlint-language-server/pull/187#issuecomment-1399925116
      client.notify("workspace/didChangeConfiguration", {
         settings = {},
      })

      if original_init then
         original_init(...)
      end
   end
end

local function start_sonarlint_lsp(user_config)
   local config = vim.tbl_deep_extend("keep", user_config, {
      root_dir = vim.fs.dirname(vim.fs.find({ ".git" }, { upward = true })[1]),
      capabilities = vim.lsp.protocol.make_client_capabilities(),
      settings = { sonarlint = {} },
   })

   config.name = "sonarlint.nvim"

   config.init_options = {
      productKey = "sonarlint.nvim",
      productName = "SonarLint.nvim",
      productVersion = "0.1.0",
      -- TODO: get workspace name
      workspaceName = "some-workspace-name",
      firstSecretDetected = false,
      showVerboseLogs = true,
      platform = vim.loop.os_uname().sysname,
      architecture = vim.loop.os_uname().machine,
   }

   config.handlers = {}

   -- TODO: sonarlint/isOpenInEditor has been replaced in
   -- sonarlint-language-server 3.0.0.74514 by sonarlint/shouldAnalyseFile.
   -- This will be kept for a while to be none-breaking for setups with older
   -- clients.
   config.handlers["sonarlint/isOpenInEditor"] = function(err, uri)
      return utils.is_open_in_editor(uri)
   end
   config.handlers["sonarlint/shouldAnalyseFile"] = function(err, uri)
      return {
         shouldBeAnalysed = utils.is_open_in_editor(uri.uri),
      }
   end

   config.handlers["sonarlint/isIgnoredByScm"] = require("sonarlint.scm").is_ignored_by_scm

   config.handlers["sonarlint/getJavaConfig"] = java.get_java_config_handler

   config.handlers["sonarlint/needCompilationDatabase"] = function(err, uri)
      local locations = vim.fs.find("compile_commands.json", {
         upward = true,
         path = vim.fs.dirname(vim.api.nvim_buf_get_name(0)),
      })
      if #locations > 0 then
         local client = vim.lsp.get_client_by_id(M.client_id)
         client.config.settings = vim.tbl_deep_extend("force", client.config.settings, {
            sonarlint = {
               pathToCompileCommands = locations[1],
            },
         })
         client.notify("workspace/didChangeConfiguration", {
            settings = {},
         })
      else
         vim.notify(
            "Couldn't find compile_commands.json. Make sure it exists in a parent directory.",
            vim.log.levels.ERROR
         )
      end
   end

   config.handlers["sonarlint/showRuleDescription"] = require("sonarlint.rules").show_rule_handler

   -- TODO: persist settings
   config.commands = {
      ["SonarLint.DeactivateRule"] = function(action)
         local rule = action.arguments[1]
         if rule ~= nil then
            local client = vim.lsp.get_client_by_id(M.client_id)
            client.config.settings = vim.tbl_deep_extend("force", client.config.settings, {
               sonarlint = {
                  rules = {
                     [rule] = {
                        level = "off",
                     },
                  },
               },
            })
            client.notify("workspace/didChangeConfiguration", {
               settings = {},
            })
         end
      end,
      ["SonarLint.ShowAllLocations"] = function(result, ...)
         local list = {}
         for i, arg in ipairs(result.arguments) do
            local bufnr = vim.uri_to_bufnr(arg.fileUri)

            for j, flow in ipairs(arg.flows) do
               for k, location in ipairs(flow.locations) do
                  local text_range = location.textRange

                  table.insert(list, {
                     bufnr = bufnr,
                     lnum = text_range.startLine,
                     col = text_range.startLineOffset,
                     end_lnum = text_range.endLine,
                     end_col = text_range.endLineOffset,
                     text = arg.message,
                  })
               end
            end
         end

         vim.fn.setqflist(list, "r")
         vim.cmd("copen")
      end,
   }

   config.on_init = init_with_config_notify(config.on_init, config.settings)

   return vim.lsp.start_client(config)
end

function M.setup(config)
   if not config.filetypes then
      vim.notify("Please, provide filetypes as a list of filetype.", vim.log.levels.WARN)
      return
   end

   local pattern = {}
   local attach_to_jdtls = false
   for i, filetype in ipairs(config.filetypes) do
      if filetype == "java" then
         attach_to_jdtls = true
      end
      table.insert(pattern, filetype)
   end

   vim.api.nvim_create_autocmd("FileType", {
      pattern = table.concat(pattern, ","),
      callback = function(buf)
         bufnr = buf.buf

         if not M.client_id then
            M.client_id = start_sonarlint_lsp(config.server)
         end

         vim.lsp.buf_attach_client(bufnr, M.client_id)
      end,
   })

   vim.api.nvim_create_autocmd({ "BufEnter", "LspAttach" }, {
      callback = require("sonarlint.scm").check_git_branch_and_notify_lsp,
   })

   if attach_to_jdtls then
      local ok, jdtls_util = pcall(function()
         return require("jdtls.util")
      end)
      if not ok then
         vim.notify(
            "nvim-jdtls isn't available and is required for analyzing Java files. Make sure to install it",
            vim.log.levels.WARN
         )
         return
      end

      if vim.lsp.handlers["$/progress"] then
         local old_handler = vim.lsp.handlers["$/progress"]
         vim.lsp.handlers["$/progress"] = function(...)
            old_handler(...)
            java.handle_progress(...)
         end
      else
         vim.lsp.handlers["$/progress"] = java.handle_progress
      end
   end
end

return M
