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

--- Compact QR + URL dialog for KOCloud phone setup.
---@class KOCloudOAuthSetupDialog: InputContainer
---@field setup_url string
---@field title_text? string
---@field instructions_text? string
---@field note_text? string
---@field close_callback? fun()
local OAuthSetupDialog = InputContainer:extend{
    modal = true,
    setup_url = nil,
    title_text = nil,
    instructions_text = nil,
    note_text = nil,
    close_callback = nil,
}

function OAuthSetupDialog:init()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local content_width = math.floor(screen_width * 0.86)
    local qr_size = math.min(
        math.floor(screen_width * 0.52),
        math.floor(screen_height * 0.42)
    )

    local title = TextBoxWidget:new{
        text = self.title_text
            or _("Configure Google OAuth from browser"),
        face = Font:getFace("cfont", 24),
        bold = true,
        width = content_width,
        alignment = "center",
    }

    local instructions = TextBoxWidget:new{
        text = self.instructions_text
            or _(
                "Scan the QR code with your phone, or open the address below "
                    .. "on a computer or another device on the same Wi-Fi network."
            ),
        face = Font:getFace("smallinfofont"),
        width = content_width,
        alignment = "center",
    }

    local qr = QRWidget:new{
        text = self.setup_url,
        width = qr_size,
        height = qr_size,
    }

    local url_label = TextBoxWidget:new{
        text = _("Setup address:"),
        face = Font:getFace("smallinfofont"),
        bold = true,
        width = content_width,
        alignment = "left",
    }

    local url_text = TextBoxWidget:new{
        text = self.setup_url,
        face = Font:getFace("smallinfofont"),
        width = content_width,
        alignment = "left",
    }

    local note = TextBoxWidget:new{
        text = self.note_text
            or _(
                "The setup server stays active for up to 5 minutes. "
                    .. "Closing this window does not stop the server."
            ),
        face = Font:getFace("xx_smallinfofont"),
        width = content_width,
        alignment = "center",
    }

    local buttons
    buttons = ButtonTable:new{
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
                VerticalSpan:new{
                    width = Size.padding.large,
                },
                instructions,
                VerticalSpan:new{
                    width = Size.padding.large,
                },
                CenterContainer:new{
                    dimen = Geom:new{
                        w = content_width,
                        h = qr:getSize().h,
                    },
                    qr,
                },
                VerticalSpan:new{
                    width = Size.padding.large,
                },
                url_label,
                url_text,
                VerticalSpan:new{
                    width = Size.padding.large,
                },
                note,
                VerticalSpan:new{
                    width = Size.padding.large,
                },
                buttons,
            },
        },
    }
end

function OAuthSetupDialog:onCloseWidget()
    UIManager:setDirty(nil, "ui")

    if self.close_callback then
        self.close_callback()
        self.close_callback = nil
    end
end

return OAuthSetupDialog
