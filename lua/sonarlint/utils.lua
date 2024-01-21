local M = {}

function M.is_open_in_editor(uri)
   for i, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if uri == vim.uri_from_bufnr(bufnr) then
         return true
      end
   end
   return false
end

function M.get_sonarlint_client()
   local clients = vim.lsp.get_active_clients({ name = "sonarlint.nvim" })

   return clients[1]
end

return M
