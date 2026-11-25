---
title: "Netskope One SD-WAN Integration with Azure Virtual WAN"
slug: "netskope-one-sd-wan-integration-with-azure-virtual-wan"
updated: 2025-12-29T11:09:02Z
published: 2025-12-29T11:09:02Z
canonical: "netskope.document360.io/netskope-one-sd-wan-integration-with-azure-virtual-wan"
---

# Netskope One SD-WAN Integration with Azure Virtual WAN

![NS-borderless-wan_NS-Borderless-WAN-Full-Color(1)](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/NS-borderless-wan_NS-Borderless-WAN-Full-Color(1).png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=ScSAdaH8Q0fcw%2FJwXT%2F460MRXaPt3%2Bq4QLNcIaLZJ3Q%3D)

## Netskope One SD-WAN Integration with Azure Virtual WAN

---

### Securing and Optimizing Any-to-Any Access with Netskope and Azure Integration

Navigating complex cloud networks with multiple clouds while ensuring secure and reliable access to workloads can be daunting. That’s why Netskope and Azure have teamed up to simplify this journey and make it a lot easier. Through the integration of Netskope One SD-WAN with Azure Virtual WAN, teams can automate workload access from any remote site and user laptop, deliver a secure, reliable, flexible, and highly available middle-mile network service leveraging the Azure global network.

A simplified workflow to establish BGP peering within a shared virtual network between Netskope One Gateway Hub and Azure vWAN provides connectivity and improved throughput performance without the need of IPSec or GRE. This collaboration streamlines network management, offering a more efficient way to accelerate cloud transformation.

### Unlocking the power of Azure vWAN with Netskope One SD-WAN

Netskope and Azure have partnered to deliver an innovative, dynamic WAN service. This dynamic solution offers the ability to establish a fully connected global network, offering automation for efficient and intuitive network management, all under a unified policy framework that enhances security and elevates application Quality of Experience (AppQoE).

The Netskope and Azure integration opens doors to seamless access through the Azure global network. This, in turn, provides access to workloads from any corner of the world, facilitates inter-office communication, fosters cross-region workload connectivity, and ensures a secure onramp to security service edge (SSE) services for Azure workloads. As a result, customers can enjoy the advantages of simplified management, on-demand deployment, and optimized performance and security.

Additionally, Azure virtual WAN offers a global WAN service across Azure cloud regions. Netskope One SD-WAN takes advantage of a straightforward workflow, which includes:

- Orchestrating the Azure VirtualWAN infrastructure and providing direct access to local Azure points of presence through BGP peering over shared virtual network.
- Extending the SD-WAN overlay and ensuring end-to-end segmentation over the Azure virtual WAN built over the Azure global network.
- Enabling centralized management and monitoring of remote sites, users, routing, AppQoE, and on-ramp to Netskope One SSE through unified policies.

All of this is achieved through the cloud-delivered, multi-tenant Netskope One SASE Orchestrator that can serve the diverse needs of any enterprise or managed service provider (MSP). This remarkable solution redefines connectivity, making it simpler, more efficient, and highly secure.

The following diagram offers a visual representation of the three use cases described below:

1. encompassing last mile
2. encompassing middle mile
3. seamless one-click access to Netskope One SSE for complete threat protection.

The example below shows two ways to provide connectivity between two SD-WAN tenants by leveraging the Azure vWAN Backbone:

1. Keeping the original Netskope ASN 400 on both sides
2. Overriding the original Netskope ASN 400 on both sides while filtering the BGP Prefixes learned and advertised with the BGP route-maps from the Portal

## Solution Topology

## ![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-wnb8k6d3.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=b%2B%2FIYslfuM3mWixeQCRtjRsGMRgwaCM%2BMoka%2BCdaevc%3D)

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-s4z8pf96.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=ceH8i8Iy57hRHdyHWqHjFCkYRSCc5m1dy8gDjIqRJfs%3D)

## **Step 1 -** Create Azure Infrastructure and Activate Netskope One Gateways

Configure Netskope One Gateways as Hubs in 2 Azure regions.

In this example, Netskope One virtual gateways have been provisioned and activated as hubs in **US-West2** and **Australia East** Azure regions.

The following steps can be used to create Azure infrastructure and activate virtual gateways in each region.

1. Create or use an existing Azure VNET and configure a virtual Gateway with 2 interfaces GE1 assigned to public subnet, GE2 assigned to private subnet.
2. The public subnet should be associated with a public route table and the private subnet should be associated with a private route table.
3. Activate the virtual gateway as a Hub.
4. GE1 of the Hub has an overlay from the branch Gateway.
5. GE2 of the Hub establishes a BGP neighborship with Azure vWAN Hub.
6. The Netskope One virtual Gateway should be deployed on both of the Azure regions.
7. For detailed information on virtual Gateway installation on Azure, refer to the [Netskope One Gateway Deployment in Azure document](/docs/netskope-one-gateway-deployment-in-azure).

## **Step 2 -** Topology in Detail

In this example, we’ve deployed 4 Gateways in Azure.

Two Spoke devices, one each in the US region and in the AUS region.

Two Hub devices, one each in the US region and in the AUS region.

**US-Branch**

This site is configured with GE1 as WAN interface and GE2 as LAN interface.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-0azhkpe1.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=pPgOI9peV8kFTsS%2B8rig059hDyGftvQxjDNN7vUOCvQ%3D)

The LAN client behind this branch is configured with an IP of 10.13.2.11

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-dgxphjum.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=oAcgegAWI8oxK7i8n%2F9sntfyP%2BVLNTprdilfw7AItAI%3D)

**US-Hub**

This site is configured with GE1 as WAN interface and GE2 as LAN interface. GE2 forms an eBGP neighborship with the Azure US vWAN Hub.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-csmxqvjm.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=AYdeGeH6Dn76W%2FBwky5HXr0d5OLQF5R%2FLIGbbOH1Bd8%3D)

**AUS-Branch**

This site is configured with GE1 as WAN interface and GE2 as LAN interface.**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-0xlgnoyk.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=hMik7inksSqNG9CY5gRhAIOalbc6bXlYIjrfS86MTHU%3D)**

The LAN client behind this branch is configured with an IP of 10.14.2.11

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-bup6zsu0.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=XsmHl255JBPnrlKFfWpYBDy4J9IOO%2FsWeCiZGVAVrLI%3D)

**AUS-Hub**

This site is configured with GE1 as WAN interface and GE2 as LAN interface. GE2 forms an EBGP neighborship with the Azure AUS vWAN Hub.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-l2vqap9v.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=1NvDgvNIP2ZPgqggJj2kJLu0Gq6D2Qmb%2F8JiTtb%2FCg0%3D)

## **Step 3 -** Create Virtual WAN, Virtual Hub and Virtual Network Connections

Log in to the Azure console and create a virtual WAN. Within the Virtual WAN, create Virtual Network Connections and Hubs.

1. Create a **Virtual WAN** specifying the resource group and region

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-39u9epij.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=GArzdtFGCQzxag4uOY7gY98%2F0LHPcKilKXxyqasqddE%3D)

1. Create **Hubs** in Australia East and US West 2 regions. Below example shows Virtual Hub **ACME-vWAN-AUS** created in Australia East region. Configure dedicated Private Address space. Select Hub routing preference as **AS Path** if it is intended to use BGP to peer between virtual Hubs and NVA (Netskope One Gateway).

Go to the **Virtual WAN** we created in Step-1, click on the “**Connectivity**” section and click on “**Hubs**”. Then click on “**New Hub**”.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-2zv87gz6.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=UYsxz6g2M7ae2uleH%2FOmuIwP1EzHfLzt8TJ6bCV%2BKyo%3D)

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-of43dynr.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=sAzrVumovSiWM%2FcLCVMSHNhgF%2B6NtvMjDr2oBNnLE1g%3D)

Leave all **other sections** with **default** settings.

1. Similarly, a Virtual Hub in US-West2 region **ACME-vWAN-US** has been created with a dedicated private address space and routing preference as **AS Path**

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-jbrbhblh.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=y%2FjJ21orZodNCjfFp1to%2FDY81Xoq%2FCUjc77h3Gqj%2FJA%3D)**

So, in total, we created two virtual HUBs as shown below.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-amp5bpbo.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=%2FbkwdenZW59%2FFxnB34M3O5oYdFHzFi85Z%2FNV9VXzE6w%3D)

1. Create **Virtual Network Connections** to link VNET associated with BWAN gateways to respective vWAN Hubs.

In this example, **ACME-AUS** VNET is added as a connection to **ACME-vWAN-AUS** Hub.

**ACME-WestUS** VNET is added as a connection to **ACME-vWAN-US** hub.

VNET routes are propagated to the **Default** route table and **Default** label is allowing this vWAN Hub to advertise these routes to remote vWAN Hubs.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-j3pjuuk9.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=kXzr%2FjFNAkZkEkuLJXZuvoJfdJ4Hw5IJtyrxeDkNZpo%3D)

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-epfitfnk.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=V9wocTHCSj1QoA8l5O5w45l3tfQF2Kn0sdNaKgWoCIw%3D)

Similarly, create the Virtual Network Connections to link **ACME-WestUS** VNET to **ACME-vWAN-US** hub. Correspondingly, the routes learned through the VNET association are propagated to the default routing table.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-1pna7m1a.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=7F0G7%2BU90yOabbAh%2FIErqgKXj7TJy%2BuiaeyhjvOv3FY%3D)

The following image shows Virtual Network Connection created to associate **ACME-AUS** VNET with **ACME-vWAN-AUS** virtual hub and **ACME-WestUS** VNET with **ACME-vWAN-US** virtual hub.

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-zs2018d8.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=AWBnU9W8iITqMufWSrsWGpkUM%2BHaXJUXvXh2Dwkhw1M%3D)**

## **Step 4 -** Create BGP Peering on Virtual Hubs

Create BGP peer configuration on Virtual Hubs. The Peer IP should be the GE2 interface IP of the Netskope One Hub Gateways. Similarly, configure BGP peering on the Netskope One Hub Gateways towards IP of the Virtual Hubs.

1. In the below example, **ACME-vWAN-AUS** hub is peered with GE2 interface IP of Netskope One Gateway Hub **ACME-AUS-Hub** and vice versa.

The ASN and IPv4 address of the Peer (Netskope One Gateway Hub) should be configured.

Select the Virtual Network Connection we created in previous steps.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-b1bgpao4.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=QbP4X%2FtVteBt4SzIiUx4XsVJbFgKJWAd%2FQBJAZCsDJM%3D)

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-65afo6w0.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=Q%2Frz4UetzyktdFiT4BeqHtYj%2FaN3ZFKsVawLyAo0plE%3D)

1. Similarly, **ACME-vWAN-US** hub is peered with GE2 interface IP of the Netskope One Gateway Hub **ACME-US-Hub** and vice-versa.

The ASN and IPv4 address of the Peer (Netskope One Gateway Hub) should be configured.

Select the Virtual Network Connection we created in previous steps.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-j9z608ah.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=DxWHTgjdw%2BZVYCfjk6nwbaT7KSkMeb5AhhwHo4sOcck%3D)

1. Now go to the SASE Orchestrator and configure the BGP neighborship between Netskope **AUS-HUB** and **AUS vWAN Virtual Hub**. Similarly, we configure the BGP neighborship between Netskope **US-HUB** and **US vWAN Virtual Hub.**

**ACME-AUS-Hub** BGP peering over its GE2 interface with **ACME-vWAN-AUS** virtual hub.

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-ndr2ydpb.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=Aij46LJUs6g1E3sPR0d3qeqP%2BK5KOQu7mBYfojjzxP0%3D)**

1. Add a static route on **ACME-AUS-Hub** for BGP neighbor reachability.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-pbm1qkex.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=uDNkmP8QyocZATo%2FcifglET1B1ylIbW7IwR7hKMV2JM%3D)

1. **ACME-US-Hub** BGP peering over its GE2 interface with **ACME-vWAN-US** virtual hub.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-msp0wvl2.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=YJGPlaRPg6lbyvm41Q00xBXS4Blb8Jgj%2FxOpNs5G1LU%3D)

1. Add a static route on **ACME-US-Hub** for BGP neighbor reachability.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-86lxtk0b.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=rfBTKiqMGE8eDWlHIO9hXZVpgU0oinQr30uWmZ35TY4%3D)

## **Step 5 -** Configure Netskope One Gateway Branches to Connect to Regional Netskope One Gateway Hubs.

1. Configure Netskope One Gateways provisioned in Azure as Hubs in branch policies. In this example, **ACME-AUS-Hub** is configured as a hub in **AUS branch policy** and **ACME-US-Hub** is configured as a hub in **US branch policy.**

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-wyww648p.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=BWWPDEZEpAcBZsYPiQC3nJ39ujtXmVUk2M%2FuwP%2F1gFg%3D)**

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-r2h3k8hu.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=1pj7ZEOMvnD4FQdMzn%2BIzGTHFR%2Ba8qounfCdq03t3Vw%3D)**

1. Advertise branch LAN subnet to the overlay. The branch LAN subnet advertisement when received via the overlay to the regional hub will be subsequently advertised to Azure vWAN backbone through their BGP peering.

Go to the LAN interface **GE2** on the ACME-US-Branch and enable the “**Advertise Subnet**” flag.

Similarly, go to the LAN interface **GE2** on the ACME-AUS-Branch and enable the “**Advertise Subnet**” flag.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-ny113f5r.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=PzbDnHsJCW6kFdKGrVgLTIDu1f%2FU3xxmyao%2FbusGWuQ%3D)

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-wj04okgt.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=IVvriA0KRRAh9Ev0LSwlDMppeWMj4BssqkjrGhm3BHo%3D)

## **Step 6 -** Verification

1. Verify the routes learned by virtual WAN Hubs **ACME-vWAN-AUS and ACME-vWAN-US**

In the Australia East Virtual Hub **ACME-vWAN-AUS**, verify route learned from local SDWAN branch site, **10.14.2.0/24** via BGP peering and remote region SDWAN branch site route **10.13.2.0/24** learned via the vWAN backbone.

Go to Virtual WAN (in this example, **ACME-vWAN**), click on “**Connectivity -> Hubs**”, then click on the virtual Hub “**ACME-vWAN-AUS**” and click on “**Routing -> Effective Routes**”.

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-cirhj6iu.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=xtMtRxmmkS6HTB%2BFoFpyPMo9fYy1FPXK7uly62JVWmk%3D)

Similarly, in the US West2 Virtual Hub **ACME-vWAN-US**, verify route learned from local SD-WAN branch site, **10.13.2.0/24** via BGP peering and remote region SD-WAN branch site route **10.14.2.0/24** learned via the vWAN backbone.

Go to Virtual WAN (in this example, **ACME-vWAN**), click on “**Connectivity -> Hubs**”, then click on the virtual Hub “**ACME-vWAN-US**” and click on “**Routing -> Effective Routes**”.

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-autotuhs.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=FImjZpaShFze8IhK9E13llf2iqMktop3193xAtEg1u0%3D)**

1. From the SASE Orchestrator, verify the routes learned on **ACME-US-Hub** and **ACME-US-Branch**

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-aimpp0n7.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=CyQhiu5VAhP9PYkFOMKl0vyNZWBrJ7T5vIeTZ0smWDQ%3D)

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-i7dkdtzu.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=8Byll3wJbm90DTd63RchXhCCQme2AvhJvqPTZsoH%2FgM%3D)

1. On the SASE Orchestrator, verify the routes learned on **ACME-AUS-Hub** and **ACME-AUS-Branch**

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-j2l9fb57.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=bxgJPwC9MI0EkovA2oEvuEmPeIr4ObwzIV8jkDhQfoc%3D)**

**![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-w25grrvg.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=LvhtNTxJ55sdnPamYcdHgBo89HrJYO%2Ft5qb3Soq%2FWuc%3D)**

## **Step 7 -** Connectivity Checks

End to End pings and MTR tests between US client **10.13.2.11** and AUS Client **10.14.2.11**

US client (**10.13.2.11)**:

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-avka3jo0.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=8XwrPrBlL4yB3CyIom5tI6zA34WU9twbKF4nrXtAmHI%3D)

AUS Client (**10.14.2.11)**:

![](https://cdn.document360.io/4a7ce51f-0979-4e94-a8ed-6c7a5afe7517/Images/Documentation/netskope-borderless-wan-integration-with-azure-virtual-wan-image-m1li95ge.png?sv=2026-02-06&spr=https&st=2026-11-23T08%3A21%3A26Z&se=2026-11-23T09%3A21%3A26Z&sr=b&sp=r&sig=A%2BZICMVMYsNNFQlr6i44Nj6v7IH%2BBY%2BHByjwtibrTEs%3D)

## **Workarounds**

Some changes to BGP configurations are needed to make end to end connectivity across Azure vWAN to work. These BGP configurations cannot be done on the SASE Orchestrator portal due to the unavailability of configuration options on the UI for BGP.

The following BGP configurations need to be made on both the Netskope One Gateway Hubs for the remote branch routes to be advertised through the Azure vWAN to the local site.

1. Allow routes with AS 400 to be received on each Netskope One Gateway Hub site. As both SD-WAN regions use AS 400 as their internal AS, SD-WAN routes can be received on remote SD-WAN sites through the Azure vWAN backbone only if they **allowas-in AS 400.**
2. Remove AS 400 from inbound SD-WAN route advertisement received from Azure Virtual hub using **set as-path exclude 400** on both Netskope One Gateway Hubs so that the route can be re-advertised via the overlay to the local branch.
3. For the purpose of matching SD-WAN routes, a community string **UPLINK** with value 55555:1 is used to mark all SD-WAN prefixes.
4. All SD-WAN routes referenced as **UPLINK** routes are now subjected to steps 1,2 above.
5. For ease of configuration of the above BGP commands, the below template is copied to the file **frrcmds-user.json (under /infroot/workdir/)** with the correct Azure vWAN neighbor on both the Netskope One GatewayHubs. Create **frrcmds-user.json** file on both the Netskope One Gateway Hubs, copy the respective below contents and save.
6. Once configured, restart the container **infhostd restart-container** (outside the docker) on both of the Netskope One Gateway Hubs for the commands to take effect.
7. Below is an example of the **frrcmds-user.json** file used for the **ACME-Aus-Hub** gateway:

```json
{

  "frrCmdSets": [

    {

      "frrCmds": [

        "conf t",

        "ip community-list standard HA_COMMUNITY permit 47474:47474"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "ip community-list standard UPLINK permit 55555:1"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "route-map backbone-in permit 1",

        "match community UPLINK",

        "set as-path exclude 400",

        "route-map backbone-in permit 10"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "ip prefix-list default seq 5 permit 0.0.0.0/0",

        "route-map advertise permit 10",

        "match ip address prefix-list default"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "route-map backbone-out permit 1",

        "match community To-HUB1",

        "set community 55555:1 additive",

        "route-map backbone-out permit 10",

        "set metric 10"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "router bgp 400",

        "address-family ipv4 unicast",

        "neighbor 10.20.32.5 allowas-in"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "router bgp 400",

        "neighbor 10.20.32.5 disable-connected-check",

        "neighbor 10.20.32.5 ebgp-multihop 2",

        "neighbor 10.20.32.5 route-map backbone-out out",

        "neighbor 10.20.32.5 route-map backbone-in in"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "route-map To-Ctrlr-1 deny 5",

        "match ip address prefix-list default",

        "route-map To-Ctrlr-2 deny 5",

        "match ip address prefix-list default",

        "route-map To-Ctrlr-3 deny 5",

        "match ip address prefix-list default",

        "route-map To-Ctrlr-4 deny 5",

        "match ip address prefix-list default"

      ]

    },

    {

      "frrCmds": [
        
        "conf t",

        "route-map From-Ctrlr-1 deny 6",

        "match community HA_COMMUNITY",

        "route-map From-Ctrlr-2 deny 6",

        "match community HA_COMMUNITY",

        "route-map From-Ctrlr-3 deny 6",

        "match community HA_COMMUNITY",

        "route-map To-Ctrlr-3 permit 10",

        "set community 47474:47474 additive",

        "route-map To-Ctrlr-2 permit 10",

        "set community 47474:47474 additive",

        "route-map To-Ctrlr-1 permit 10",

        "set community 47474:47474 additive",

        "route-map To-Ctrlr-4 permit 10",

        "set community 47474:47474 additive"

      ]

    }

  ]

}
```

1. Below is an example of the **frrcmds-user.json** file used for the **ACME-US-Hub** gateway:

```json
{

  "frrCmdSets": [

    {

      "frrCmds": [

        "conf t",

        "ip community-list standard HA_COMMUNITY permit 47474:47474"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "ip community-list standard UPLINK permit 55555:1"                    

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "route-map backbone-in permit 1",

        "match community UPLINK",

        "set as-path exclude 400",                                  

        "route-map backbone-in permit 10"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "ip prefix-list default seq 5 permit 0.0.0.0/0",

        "route-map advertise permit 10",                         

        "match ip address prefix-list default"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "route-map backbone-out permit 1",

        "match community To-HUB1",

        "set community 55555:1 additive",

        "route-map backbone-out permit 10",

        "set metric 10"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "router bgp 400",

        "address-family ipv4 unicast",

        "neighbor 10.10.32.4 allowas-in"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "router bgp 400",

        "neighbor 10.10.32.4 disable-connected-check",

        "neighbor 10.10.32.4 ebgp-multihop 2",

        "neighbor 10.10.32.4 route-map backbone-out out",

        "neighbor 10.10.32.4 route-map backbone-in in"

      ]

    },

    {

      "frrCmds": [

        "conf t",

        "route-map To-Ctrlr-1 deny 5",

        "match ip address prefix-list default",                   

        "route-map To-Ctrlr-2 deny 5",

        "match ip address prefix-list default",

        "route-map To-Ctrlr-3 deny 5",

        "match ip address prefix-list default",

        "route-map To-Ctrlr-4 deny 5",

        "match ip address prefix-list default"

      ]

    },

    {

      "frrCmds": [
        
        "conf t",
        
        "route-map From-Ctrlr-1 deny 6",

        "match community HA_COMMUNITY",

        "route-map From-Ctrlr-2 deny 6",

        "match community HA_COMMUNITY",

        "route-map From-Ctrlr-3 deny 6",

        "match community HA_COMMUNITY",

        "route-map To-Ctrlr-3 permit 10",

        "set community 47474:47474 additive",               

        "route-map To-Ctrlr-2 permit 10",

        "set community 47474:47474 additive",

        "route-map To-Ctrlr-1 permit 10",

        "set community 47474:47474 additive",

        "route-map To-Ctrlr-4 permit 10",

        "set community 47474:47474 additive"

      ]

    }

  ]

}
```