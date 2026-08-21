local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Screen = Device.screen

--- Compact QR dialog for importing existing Google Drive books.
---
--- This is intentionally separate from the OAuth setup dialog. The import
--- flow needs less explanatory text, and keeping this panel small prevents
--- modal content from extending outside smaller KOReader screens.
---@class KOCloudDriveImportDialog: InputContainer
---@field import_url string
---@field close_callback? fun()
local DriveImportDialog = InputContainer:extend{
    modal = true,
    import_url = nil,
    close_callback = nil,
}

function DriveImportDialog:init()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local content_width = math.floor(screen_width * 0.82)
    local qr_size = math.min(
        math.floor(screen_width * 0.38),
        math.floor(screen_height * 0.28)
    )

    local title = TextBoxWidget:new{
        text = _("Import from Google Drive"),
        face = Font:getFace("cfont", 22),
        bold = true,
        width = content_width,
        alignment = "center",
    }

    local instructions = TextBoxWidget:new{
        text = _(
            "Scan the QR code or open the address below "
                .. "on another device."
        ),
        face = Font:getFace("smallinfofont"),
        width = content_width,
        alignment = "center",
    }

    local qr = QRWidget:new{
        text = self.import_url,
        width = qr_size,
        height = qr_size,
    }

    local url_text = TextBoxWidget:new{
        text = self.import_url,
        face = Font:getFace("xx_smallinfofont"),
        width = content_width,
        alignment = "center",
    }

    local note = TextBoxWidget:new{
        text = _("The import session expires after 5 minutes."),
        face = Font:getFace("xx_smallinfofont"),
        width = content_width,
        alignment = "center",
    }

    local buttons = ButtonTable:new{
        width = content_width,
        buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(self)
                    end,
                },
            },
        },
        show_parent = self,
    }

    local gap = Size.padding.default

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.large,
            VerticalGroup:new{
                align = "center",
                title,
                VerticalSpan:new{ width = gap },
                instructions,
                VerticalSpan:new{ width = gap },
                CenterContainer:new{
                    dimen = Geom:new{
                        w = content_width,
                        h = qr:getSize().h,
                    },
                    qr,
                },
                VerticalSpan:new{ width = gap },
                url_text,
                VerticalSpan:new{ width = gap },
                note,
                VerticalSpan:new{ width = gap },
                buttons,
            },
        },
    }
end

function DriveImportDialog:onCloseWidget()
    UIManager:setDirty(nil, "ui")

    if self.close_callback then
        self.close_callback()
        self.close_callback = nil
    end
end

return DriveImportDialog
