package resources

import (
	"context"
	"fmt"

	"github.com/Daily-Nerd/terraform-provider-omada/internal/client"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var _ resource.Resource = &DhcpReservationResource{}
var _ resource.ResourceWithImportState = &DhcpReservationResource{}

// DhcpReservationResource manages an Omada DHCP reservation.
type DhcpReservationResource struct {
	client *client.Client
}

// DhcpReservationResourceModel maps the resource schema to Go types.
type DhcpReservationResourceModel struct {
	ID          types.String `tfsdk:"id"`
	SiteID      types.String `tfsdk:"site_id"`
	NetworkID   types.String `tfsdk:"network_id"`
	NetworkName types.String `tfsdk:"network_name"`
	MAC         types.String `tfsdk:"mac"`
	ClientName  types.String `tfsdk:"client_name"`
	IP          types.String `tfsdk:"ip"`
	IPStart     types.Int64  `tfsdk:"ip_start"`
	IPEnd       types.Int64  `tfsdk:"ip_end"`
	Description types.String `tfsdk:"description"`
	Enabled     types.Bool   `tfsdk:"enabled"`
	// todo: what are these for?
	ExportToIPMacBinding types.Bool `tfsdk:"export_to_ip_mac_binding"`
	Options              types.List `tfsdk:"options"`
	// ExistOptions         types.List `tfsdk:"exist_options"`
}

func NewDhcpReservationResource() resource.Resource {
	return &DhcpReservationResource{}
}

func (r *DhcpReservationResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_dhcp_reservation"
}

func (r *DhcpReservationResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages a DHCP reservation on the Omada site.",
		Attributes: map[string]schema.Attribute{
			"id": schema.StringAttribute{
				Description: "The unique identifier of the DHCP reservation.",
				Computed:    true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			// todo: do I need to specify the site_id in the resource schema? I think so, because the API requires it for all operations. But it seems redundant, since the network_id already implies the site_id. Maybe I can validate that they match.
			"site_id": siteIDResourceSchema(),
			"network_id": schema.StringAttribute{
				Description: "The ID of the network to which the DHCP reservation belongs.",
				Required:    true,
			},
			"mac": schema.StringAttribute{
				Description: "The MAC address of the device for which to create a DHCP reservation.",
				Required:    true,
			},
			"client_name": schema.StringAttribute{
				Description: "The name of the client for which to create a DHCP reservation.",
				Computed:    true,
			},
			"ip": schema.StringAttribute{
				Description: "The IP address for the DHCP reservation.",
				Required:    true,
			},
			"ip_start": schema.Int64Attribute{
				Description: "The starting IP address for the DHCP reservation.",
				Required:    false,
				Computed:    true,
			},
			"ip_end": schema.Int64Attribute{
				Description: "The ending IP address for the DHCP reservation.",
				Required:    false,
				Computed:    true,
			},
			"description": schema.StringAttribute{
				Description: "The description for the DHCP reservation.",
				Optional:    true,
			},
			// todo: rename
			"enabled": schema.BoolAttribute{
				Description: "Whether the DHCP reservation is enabled.",
				Required:    true,
			},
			"export_to_ip_mac_binding": schema.BoolAttribute{
				Description: "Whether to export the DHCP reservation to the IP-MAC binding list.",
				Optional:    true,
			},
			"options": schema.ListAttribute{
				Description: "The DHCP options for the DHCP reservation.",
				ElementType: types.StringType,
				Optional:    true,
			},
			// "exist_options": schema.ListAttribute{
			// 	Description: "The existing DHCP options for the DHCP reservation.",
			// 	ElementType: types.StringType,
			// 	Computed:    true,
			// },
			"network_name": schema.StringAttribute{
				Description: "The name of the network to which the DHCP reservation belongs.",
				Computed:    true,
			},
		},
	}
}

func (r *DhcpReservationResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*client.Client)

	// todo:
	// - validate/normalize MAC address format
	// - validate IP address format
	// - validate referenced network existd
	// - validate referenced network purpose = inferface
	// - validate referenced network is in the same site as the DHCP reservation
	// - validate referenced network has DHCP enabled
	// - validate referenced network has a DHCP pool that includes the IP address of the DHCP reservation

	// 	The issue’s “plan-time CIDR validation” has an important limitation: when network_id comes from a newly-created omada_network, it is unknown during planning. I recommend:
	// Validate during planning when network_id is already known, using ResourceWithModifyPlan.
	// Always repeat validation immediately before create/update.
	// Defer it cleanly when the network ID is unknown.
	// This avoids adding a redundant network_cidr argument while still producing early errors whenever possible.

	if !ok {
		resp.Diagnostics.AddError(
			"Unexpected Resource Configure Type",
			fmt.Sprintf("Expected *client.Client, got: %T", req.ProviderData),
		)
		return
	}
	r.client = c
}

func (r *DhcpReservationResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan DhcpReservationResourceModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	siteID := plan.SiteID.ValueString()

	createReq := &client.DhcpReservationCreateRequest{
		NetworkID:   plan.NetworkID.ValueString(),
		MAC:         plan.MAC.ValueString(),
		ClientName:  plan.ClientName.ValueString(),
		IP:          plan.IP.ValueString(),
		IPStart:     plan.IPStart.ValueInt64(),
		IPEnd:       plan.IPEnd.ValueInt64(),
		Description: plan.Description.ValueString(),
		Status:      plan.Enabled.ValueBool(),
	}

	_, err := r.client.CreateDHCPReservation(ctx, siteID, createReq)
	if err != nil {
		resp.Diagnostics.AddError("Error creating DHCP reservation", err.Error())
		return
	}

	// Read back the created reservation to populate all computed fields
	reservation, err := r.client.GetDHCPReservation(ctx, siteID, plan.MAC.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("Error reading created DHCP reservation", err.Error())
		return
	}

	plan.ID = types.StringValue(reservation.ID)
	plan.NetworkID = types.StringValue(reservation.NetworkID)
	plan.MAC = types.StringValue(reservation.MAC)
	plan.ClientName = types.StringValue(reservation.ClientName)
	plan.IP = types.StringValue(reservation.IP)
	plan.IPStart = types.Int64Value(reservation.IPStart)
	plan.IPEnd = types.Int64Value(reservation.IPEnd)
	plan.Description = types.StringValue(reservation.Description)
	plan.Enabled = types.BoolValue(reservation.Status)
	plan.NetworkName = types.StringValue(reservation.NetworkName)

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *DhcpReservationResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state DhcpReservationResourceModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	siteID := state.SiteID.ValueString()
	reservation, err := r.client.GetDHCPReservation(ctx, siteID, state.MAC.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("Error reading DHCP reservation", err.Error())
		return
	}

	state.ID = types.StringValue(reservation.ID)
	state.NetworkID = types.StringValue(reservation.NetworkID)
	state.MAC = types.StringValue(reservation.MAC)
	state.ClientName = types.StringValue(reservation.ClientName)
	state.IP = types.StringValue(reservation.IP)
	state.IPStart = types.Int64Value(reservation.IPStart)
	state.IPEnd = types.Int64Value(reservation.IPEnd)
	state.Description = types.StringValue(reservation.Description)
	state.Enabled = types.BoolValue(reservation.Status)
	state.NetworkName = types.StringValue(reservation.NetworkName)

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *DhcpReservationResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan DhcpReservationResourceModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	var state DhcpReservationResourceModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	siteID := state.SiteID.ValueString()
	updateReq := &client.DhcpReservationCreateRequest{
		NetworkID:   plan.NetworkID.ValueString(),
		MAC:         plan.MAC.ValueString(),
		ClientName:  plan.ClientName.ValueString(),
		IP:          plan.IP.ValueString(),
		IPStart:     plan.IPStart.ValueInt64(),
		IPEnd:       plan.IPEnd.ValueInt64(),
		Description: plan.Description.ValueString(),
		Status:      plan.Enabled.ValueBool(),
	}

	success, err := r.client.UpdateDHCPReservation(ctx, siteID, updateReq)
	if err != nil {
		resp.Diagnostics.AddError("Error updating DHCP reservation", err.Error())
		return
	}
	if !success {
		resp.Diagnostics.AddError("Error updating DHCP reservation", "Update operation was not successful")
		return
	}

	// Read back the updated reservation to populate all computed fields
	reservation, err := r.client.GetDHCPReservation(ctx, siteID, state.MAC.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("Error reading updated DHCP reservation", err.Error())
		return
	}

	plan.ID = types.StringValue(reservation.ID)
	plan.NetworkID = types.StringValue(reservation.NetworkID)
	plan.MAC = types.StringValue(reservation.MAC)
	plan.ClientName = types.StringValue(reservation.ClientName)
	plan.IP = types.StringValue(reservation.IP)
	plan.IPStart = types.Int64Value(reservation.IPStart)
	plan.IPEnd = types.Int64Value(reservation.IPEnd)
	plan.Description = types.StringValue(reservation.Description)
	plan.Enabled = types.BoolValue(reservation.Status)
	plan.NetworkName = types.StringValue(reservation.NetworkName)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *DhcpReservationResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state DhcpReservationResourceModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	siteID := state.SiteID.ValueString()
	success, err := r.client.DeleteDHCPReservation(ctx, siteID, state.MAC.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("Error deleting DHCP reservation", err.Error())
		return
	}
	if !success {
		resp.Diagnostics.AddError("Error deleting DHCP reservation", "Delete operation was not successful")
		return
	}
}

func (r *DhcpReservationResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	// todo: how does this work?
	reservation, err := r.client.GetDHCPReservation(ctx, req.ID, req.ID)
	if err != nil {
		resp.Diagnostics.AddError("Error importing DHCP reservation", err.Error())
		return
	}

	state := DhcpReservationResourceModel{
		ID: types.StringValue(reservation.ID),
		// todo: the api doesn't return site_id, but I think this is fine because
		// we can get it via the network_id anyway, and not store site_id in DhcpReservationResourceModel
		// SiteID:      types.StringValue(reservation.SiteID),
		NetworkID:   types.StringValue(reservation.NetworkID),
		MAC:         types.StringValue(reservation.MAC),
		ClientName:  types.StringValue(reservation.ClientName),
		IP:          types.StringValue(reservation.IP),
		IPStart:     types.Int64Value(reservation.IPStart),
		IPEnd:       types.Int64Value(reservation.IPEnd),
		Description: types.StringValue(reservation.Description),
		Enabled:     types.BoolValue(reservation.Status),
		NetworkName: types.StringValue(reservation.NetworkName),
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}
