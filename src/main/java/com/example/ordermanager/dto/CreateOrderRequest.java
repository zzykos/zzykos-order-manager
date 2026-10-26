package com.example.ordermanager.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.ArrayList;
import java.util.List;

public class CreateOrderRequest {

    @NotBlank(message = "El nombre del cliente es obligatorio")
    @Size(max = 100, message = "El nombre no puede superar 100 caracteres")
    private String customerName;

    @Valid
    private List<AddItemRequest> items = new ArrayList<>();

    public CreateOrderRequest() {}

    public String getCustomerName() { return customerName; }
    public void setCustomerName(String customerName) { this.customerName = customerName; }
    public List<AddItemRequest> getItems() { return items; }
    public void setItems(List<AddItemRequest> items) { this.items = items; }
}
